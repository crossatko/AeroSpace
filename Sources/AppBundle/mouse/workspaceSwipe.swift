import AppKit
import Common
import os

// Built-in trackpad workspace swipe. A listen-only session event tap on gesture events
// (CGEventType 29; NSEvent global monitors do not receive touches) feeds SwipeTracker, and a
// completed swipe switches the monitor under the cursor to its next/previous workspace.
// Approach from Skyland's gestures.swift and SwipeAeroSpace (MediosZ), both MIT.
//
// The tap must run on the MAIN run loop: on other threads NSEvent.allTouches() is empty.
// The macOS gesture with the same finger count must be turned off in System Settings > Trackpad.

nonisolated(unsafe) private var swipeTap: CFMachPort? = nil
nonisolated(unsafe) private var tracker = SwipeTracker()
private let swipeSettings = OSAllocatedUnfairLock<Gestures>(initialState: Gestures())

@MainActor func syncWorkspaceSwipe(_ config: Config) {
    let g = config.gestures
    swipeSettings.withLock { $0 = g }
    tracker = SwipeTracker(fingers: g.workspaceSwipeFingers, threshold: Double(g.workspaceSwipeThreshold) / 100, natural: g.workspaceSwipeNatural)
    if let tap = unsafe swipeTap {
        CGEvent.tapEnable(tap: tap, enable: g.workspaceSwipe)
        return
    }
    guard g.workspaceSwipe else { return }
    let mask: CGEventMask = 1 << CGEventMask(NSEvent.EventType.gesture.rawValue)
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
        eventsOfInterest: mask, callback: swipeCallback, userInfo: nil,
    ) else { return }
    unsafe swipeTap = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
}

private func swipeCallback(_: CGEventTapProxy, type: CGEventType, event: CGEvent, _: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = unsafe swipeTap { CGEvent.tapEnable(tap: tap, enable: swipeSettings.withLock { $0.workspaceSwipe }) }
        return Unmanaged.passUnretained(event)
    }
    guard swipeSettings.withLock({ $0.workspaceSwipe }), let ns = NSEvent(cgEvent: event) else {
        return Unmanaged.passUnretained(event)
    }
    let samples = ns.allTouches().map {
        TouchSample(
            x: Double($0.normalizedPosition.x), y: Double($0.normalizedPosition.y),
            isResting: $0.isResting, isEnded: $0.phase == .ended || $0.phase == .cancelled,
        )
    }
    let time = ns.timestamp
    MainActor.assumeIsolated { // the tap runs on the main run loop
        if let action = tracker.feed(samples, at: time) { performSwipe(action) }
    }
    return Unmanaged.passUnretained(event)
}

@MainActor private func performSwipe(_ action: SwipeAction) {
    let g = swipeSettings.withLock { $0 }
    Task { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        try? await runLightSession(.hotkeyBinding, token) {
            let current = mouseLocation.monitorApproximation.activeWorkspace
            // Same logic as `workspace next|prev [--wrap-around]`; the list is restricted to
            // non-empty workspaces (plus the current one) when skip-empty is on.
            var names: String? = nil
            if g.workspaceSwipeSkipEmpty {
                let monitorOrigin = current.workspaceMonitor.rect.topLeftCorner
                names = Workspace.all
                    .filter { $0.workspaceMonitor.rect.topLeftCorner == monitorOrigin }
                    .filter { $0 == current || !$0.isEffectivelyEmpty }
                    .sorted().map(\.name).joined(separator: " ")
            }
            var ignoredErrors: [String] = []
            let target = getNextPrevWorkspace(
                current: current, isNext: action == .next, wrapAround: g.workspaceSwipeWrap,
                stdin: names, target: current.toLiveFocus(),
            )
            if let ws = target.getOrNil(appendErrorTo: &ignoredErrors), ws != current { _ = ws.focusWorkspace() }
        }
    }
}
