import AppKit
import ApplicationServices
import PrivateApi

// Focus a window without raising it. Re-implementation of the technique in yabai's
// `window_manager_focus_window_without_raise` (https://github.com/koekeishiya/yabai, MIT):
//   1. (only if the app is already frontmost on ANOTHER window) post a "defocus old / focus new" record pair,
//   2. _SLPSSetFrontProcessWithOptions(psn, windowId, kCPSUserGenerated) makes the app front without ordering windows,
//   3. two SLPSPostEventRecordTo records (0x01, 0x02) make the target window key.
// The private SkyLight symbols are resolved with dlsym; if one is missing everything falls back to raising.
// Written from the MIT yabai source only; AutoRaise (GPL) was not consulted for code.

private typealias SetFrontFn = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Int32
private typealias PostEventFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>) -> Int32
private typealias GetPsnFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32

private let kCPSUserGenerated: UInt32 = 0x200

@unsafe private struct SkyLightSymbols: @unchecked Sendable {
    let setFront: SetFrontFn
    let postEvent: PostEventFn
    let getPsn: GetPsnFn

    static let shared: SkyLightSymbols? = {
        guard let sl = unsafe dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let app = unsafe dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let a = unsafe dlsym(sl, "_SLPSSetFrontProcessWithOptions"),
              let b = unsafe dlsym(sl, "SLPSPostEventRecordTo"),
              let c = unsafe dlsym(app, "GetProcessForPID")
        else { return nil }
        return unsafe SkyLightSymbols(
            setFront: unsafe unsafeBitCast(a, to: SetFrontFn.self),
            postEvent: unsafe unsafeBitCast(b, to: PostEventFn.self),
            getPsn: unsafe unsafeBitCast(c, to: GetPsnFn.self),
        )
    }()
}

var isNoRaiseFocusAvailable: Bool { unsafe SkyLightSymbols.shared != nil }

private func setWindowId(_ bytes: inout [UInt8], _ wid: UInt32) {
    for i in 0 ..< 4 { bytes[0x3c + i] = UInt8((wid >> (8 * UInt32(i))) & 0xff) } // little endian
}

/// Returns false if the symbols are missing or any SkyLight call failed. Blocking (usleep + AX): call off the main actor.
nonisolated func focusWindowWithoutRaise(pid: pid_t, windowId: UInt32) -> Bool {
    guard let sl = unsafe SkyLightSymbols.shared else { return false }
    var psn = [UInt32](repeating: 0, count: 2)
    if psn.withUnsafeMutableBytes({ sl.getPsn(pid, $0.baseAddress.orDie()) }) != 0 { return false }
    var bytes = [UInt8](repeating: 0, count: 0x100)

    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
       let old = axFocusedWindowId(pid: pid), old != windowId
    {
        bytes[0x04] = 0xf8
        bytes[0x08] = 0x0d
        bytes[0x8a] = 0x02 // defocus the old window
        setWindowId(&bytes, old)
        _ = psn.withUnsafeMutableBytes { sl.postEvent($0.baseAddress.orDie(), &bytes) }
        usleep(40000)
        bytes[0x8a] = 0x01 // focus the new one
        setWindowId(&bytes, windowId)
        _ = psn.withUnsafeMutableBytes { sl.postEvent($0.baseAddress.orDie(), &bytes) }
    }

    let r1 = psn.withUnsafeMutableBytes { sl.setFront($0.baseAddress.orDie(), windowId, kCPSUserGenerated) }
    bytes = [UInt8](repeating: 0, count: 0x100)
    bytes[0x04] = 0xf8
    bytes[0x3a] = 0x10
    setWindowId(&bytes, windowId)
    for i in 0 ..< 0x10 { bytes[0x20 + i] = 0xff }
    bytes[0x08] = 0x01
    let r2 = psn.withUnsafeMutableBytes { sl.postEvent($0.baseAddress.orDie(), &bytes) }
    bytes[0x08] = 0x02
    let r3 = psn.withUnsafeMutableBytes { sl.postEvent($0.baseAddress.orDie(), &bytes) }
    return r1 == 0 && r2 == 0 && r3 == 0
}

nonisolated func axFocusedWindowId(pid: pid_t) -> UInt32? {
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard unsafe AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    var id: UInt32 = 0
    return unsafe _AXUIElementGetWindow(value as! AXUIElement, &id) == .success ? id : nil
}

/// Polls AX (max ~120 ms) until the app reports `windowId` as its focused window and the app is frontmost
nonisolated func verifyNoRaiseFocus(pid: pid_t, windowId: UInt32) -> Bool {
    for _ in 0 ..< 12 {
        if axFocusedWindowId(pid: pid) == windowId,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
        usleep(10000)
    }
    return false
}
