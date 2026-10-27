import AppKit
import Common
import os

// Magic Mouse workspace swipe. NSEvent.allTouches() only reports trackpads, so raw contacts come from the
// private MultitouchSupport framework (loaded with dlopen; if it or a symbol is missing the feature is
// silently off). Contacts are converted to TouchSamples and fed to a SwipeTracker; a completed swipe
// reuses performSwipe of the trackpad swipe. Contact callbacks run on a private thread, so all state they
// touch is lock protected and the workspace switch hops to the main actor.
//
// The macOS "Swipe between full-screen apps" gesture of the mouse should be turned off in
// System Settings > Mouse > More Gestures.

private typealias MTCreateList = @convention(c) () -> Unmanaged<CFArray>?
private typealias MTBoolFn = @convention(c) (UnsafeMutableRawPointer) -> Bool
private typealias MTInt32OutFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>) -> Int32
private typealias MTUInt64OutFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
private typealias MTContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
private typealias MTRegister = @convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void
private typealias MTStartStop = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
private typealias MTStop = @convention(c) (UnsafeMutableRawPointer) -> Void

private struct MultitouchApi: @unchecked Sendable {
    let createList: MTCreateList
    let isBuiltIn: MTBoolFn
    let familyId: MTInt32OutFn
    let deviceId: MTUInt64OutFn?
    let register: MTRegister
    let unregister: MTRegister?
    let start: MTStartStop
    let stop: MTStop
}

private let multitouchApi: MultitouchApi? = {
    guard let h = unsafe dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else { return nil }
    guard let create = unsafe dlsym(h, "MTDeviceCreateList"), let builtIn = unsafe dlsym(h, "MTDeviceIsBuiltIn"),
          let family = unsafe dlsym(h, "MTDeviceGetFamilyID"), let reg = unsafe dlsym(h, "MTRegisterContactFrameCallback"),
          let start = unsafe dlsym(h, "MTDeviceStart"), let stop = unsafe dlsym(h, "MTDeviceStop")
    else { return nil }
    return unsafe MultitouchApi(
        createList: unsafeBitCast(create, to: MTCreateList.self),
        isBuiltIn: unsafeBitCast(builtIn, to: MTBoolFn.self),
        familyId: unsafeBitCast(family, to: MTInt32OutFn.self),
        deviceId: dlsym(h, "MTDeviceGetDeviceID").map { unsafeBitCast($0, to: MTUInt64OutFn.self) },
        register: unsafeBitCast(reg, to: MTRegister.self),
        unregister: dlsym(h, "MTUnregisterContactFrameCallback").map { unsafeBitCast($0, to: MTRegister.self) },
        start: unsafeBitCast(start, to: MTStartStop.self),
        stop: unsafeBitCast(stop, to: MTStop.self),
    )
}()

private struct MouseSwipeState: Sendable {
    var enabled = false
    var tracker = SwipeTracker()
}

private let mouseState = OSAllocatedUnfairLock<MouseSwipeState>(initialState: MouseSwipeState())
nonisolated(unsafe) private var startedDevices: [UInt64: AnyObject] = [:] // main actor only
nonisolated(unsafe) private var rescanTimer: Timer? = nil // main actor only

@MainActor func syncMagicMouseSwipe(_ config: Config) {
    let g = config.gestures
    let enabled = g.magicMouseSwipe && multitouchApi != nil
    mouseState.withLock {
        $0.enabled = enabled
        $0.tracker = SwipeTracker(
            fingers: g.magicMouseSwipeFingers, threshold: Double(g.magicMouseSwipeThreshold) / 100, natural: g.workspaceSwipeNatural,
        )
    }
    if enabled {
        rescanMagicMice()
        if rescanTimer == nil { // hot-plug: cheap periodic rescan
            rescanTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                MainActor.assumeIsolated { rescanMagicMice() }
            }
        }
    } else {
        rescanTimer?.invalidate()
        rescanTimer = nil
        stopAllMagicMice()
    }
}

@MainActor private func rescanMagicMice() {
    guard let api = multitouchApi, let list = unsafe api.createList()?.takeRetainedValue() as? [AnyObject] else { return }
    var present: [UInt64: AnyObject] = [:]
    for dev in list {
        let p = unsafe Unmanaged.passUnretained(dev).toOpaque()
        var family: Int32 = 0
        guard unsafe api.familyId(p, &family) == 0, isMagicMouseDevice(isBuiltIn: unsafe api.isBuiltIn(p), familyId: family) else { continue }
        var id = UInt64(UInt(bitPattern: p))
        if let f = api.deviceId { var raw: UInt64 = 0; if unsafe f(p, &raw) == 0 { id = raw } }
        present[id] = dev
    }
    for (id, dev) in unsafe startedDevices where present[id] == nil { // unplugged
        stopMagicMouse(dev)
        unsafe startedDevices[id] = nil
    }
    for (id, dev) in present where unsafe startedDevices[id] == nil {
        let p = unsafe Unmanaged.passUnretained(dev).toOpaque()
        unsafe api.register(p, magicMouseContactCallback)
        unsafe api.start(p, 0)
        unsafe startedDevices[id] = dev
    }
}

@MainActor private func stopAllMagicMice() {
    for dev in unsafe startedDevices.values { stopMagicMouse(dev) }
    unsafe startedDevices = [:]
}

private func stopMagicMouse(_ dev: AnyObject) {
    guard let api = multitouchApi else { return }
    let p = unsafe Unmanaged.passUnretained(dev).toOpaque()
    if let u = api.unregister { unsafe u(p, magicMouseContactCallback) }
    unsafe api.stop(p)
}

// Layout of one MultitouchSupport contact (96 bytes): state at 20, normalized position at 32 / 36.
private let contactStride = 96

private let magicMouseContactCallback: MTContactCallback = { _, touches, count, timestamp, _ in
    guard mouseState.withLock({ $0.enabled }) else { return 0 }
    var samples: [TouchSample] = []
    if let touches, count > 0 {
        for i in 0 ..< Int(count) {
            let base = unsafe touches + i * contactStride
            let state = unsafe base.load(fromByteOffset: 20, as: Int32.self)
            let x = unsafe base.load(fromByteOffset: 32, as: Float.self)
            let y = unsafe base.load(fromByteOffset: 36, as: Float.self)
            samples.append(magicMouseSample(x: Double(x), y: Double(y), state: state))
        }
    }
    let frame = samples
    if let action = mouseState.withLock({ $0.tracker.feed(frame, at: timestamp) }) {
        Task.startUnstructured { @MainActor in performSwipe(action) }
    }
    return 0
}
