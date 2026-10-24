import AppKit

// Ported from Skyland (MIT, https://github.com/waxdred/skyland): the mouse drag tap
// runs on its own thread. Every click of every app goes through it, and on the main run
// loop it would wait for whatever the main thread is busy with (refresh sessions,
// layouts). The callback lets the events AeroSpace does not want through right away and
// only hops to the main thread for the ones it may consume.

nonisolated(unsafe) private let tapRunLoop: CFRunLoop = {
    let ready = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var loop: CFRunLoop? = nil
    let thread = Thread {
        loop = CFRunLoopGetCurrent()
        RunLoop.current.add(NSMachPort(), forMode: .default) // keeps the run loop alive until a tap is added
        ready.signal()
        RunLoop.current.run()
    }
    thread.name = "aerospace mouse drag tap"
    thread.qualityOfService = .userInteractive
    thread.start()
    ready.wait()
    return unsafe loop!
}()

/// Runs `tap` on the event tap thread.
func addToEventTapThread(_ tap: CFMachPort) {
    CFRunLoopAddSource(tapRunLoop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    CFRunLoopWakeUp(tapRunLoop)
}

/// From an event tap callback: runs `body` on the main thread and waits for it.
func onMainForTap<T: Sendable>(_ body: @MainActor () -> T) -> T {
    DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
}
