import AppKit
import Common
import os

// Hyprland `bindm = SUPER, mouse:272, movewindow` / `mouse:273, resizewindow`.
// With `mouse-modifier` held, a left drag anywhere on a window moves it and a right
// drag resizes it from the nearest corner. Ported from Skyland (MIT,
// https://github.com/crossatko/skyland, skyland/mouseDrag.swift), without the live
// feedback and the drop preview.
//
// While the drag runs only the window frame is changed with AX. At mouse up the
// upstream mouse handling (moveWithMouse / resizeWithMouse, normally driven by AX
// moved/resized notifications while the left button is down) is applied once: a tile
// swaps with the tile under the cursor, a resize redistributes the weights, a floating
// window changes workspace when dropped on another monitor. AeroSpace's own
// AX writes do not produce those notifications for right-button drags, hence the
// direct calls. Clicks with exactly the modifier are swallowed, everything else
// (no modifier, extra modifiers like Option+Shift) passes through untouched.
//
// mouse-modifier = 'alt'   # alt | cmd | ctrl | shift, combined with '-' (ctrl-alt); '' = off

struct MouseDrag {
    let window: Window
    let resize: Bool
    let startMouse: CGPoint
    let startRect: CGRect
    let fromLeft: Bool, fromTop: Bool // corner being dragged when resizing
    var throttle = DragThrottle()
    /// Cursor position from the tap: the drag events are swallowed, so
    /// NSEvent.mouseLocation stays frozen at the mouse down point.
    var current: CGPoint
    /// Tile the dragged window last took over (live grid), to relayout only on a change
    var lastTarget: UInt32? = nil
}

/// True from mouse down to the end of the commit at mouse up: AX moved/resized
/// notifications (our own frame writes, the neighbours following the live layout) must not
/// start refresh sessions that lay the dragged window back into its tile mid-drag.
@MainActor var isMouseDragInProgress = false
/// Live feedback (layout) of a drag event that is still running; later events are skipped
/// until it is done, the trailing update / mouse up catches up.
@MainActor private var feedbackTask: Task<Void, Never>? = nil
@MainActor private var trailingTask: Task<Void, Never>? = nil

@MainActor private var mouseDrag: MouseDrag? = nil {
    didSet { mouseDragActive.withLock { [active = mouseDrag != nil] in $0 = active } }
}
/// mouseDrag != nil, readable from the event tap thread
private let mouseDragActive = OSAllocatedUnfairLock(initialState: false)
/// Drop point while mouse up is handled (see `mouseLocation`)
@MainActor var mouseDragDropLocation: CGPoint? = nil

private let modifierMask: CGEventFlags = [.maskAlternate, .maskCommand, .maskControl, .maskShift]

/// '' -> nil (off), nil also for an unknown name
func parseMouseModifier(_ raw: String) -> CGEventFlags? {
    if raw.isEmpty { return nil }
    var flags: CGEventFlags = []
    for part in raw.lowercased().split(separator: "-") {
        switch part {
            case "alt", "option": flags.insert(.maskAlternate)
            case "cmd", "command": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "shift": flags.insert(.maskShift)
            default: return nil
        }
    }
    return flags
}

/// The exact modifier set: extra modifiers (Option+Shift for `alt`) don't match
func mouseModifierMatches(_ flags: CGEventFlags, wanted: CGEventFlags) -> Bool {
    !wanted.isEmpty && flags.intersection(modifierMask) == wanted
}

/// Frame of a window resized by the cursor delta from the corner (or edge side) it was grabbed at
func resizedDragFrame(start r: CGRect, dx: CGFloat, dy: CGFloat, fromLeft: Bool, fromTop: Bool, minSize: CGFloat = 120) -> CGRect {
    let width = max(minSize, r.width + (fromLeft ? -dx : dx))
    let height = max(minSize, r.height + (fromTop ? -dy : dy))
    return CGRect(x: fromLeft ? r.maxX - width : r.minX, y: fromTop ? r.maxY - height : r.minY, width: width, height: height)
}

nonisolated(unsafe) private var tap: CFMachPort? = nil // set once at startup

@MainActor
func startMouseDragTap() {
    if unsafe tap != nil { return }
    let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged, .rightMouseUp]
    let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    unsafe tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                   eventsOfInterest: mask, callback: mouseDragCallback, userInfo: nil)
    guard let tap = unsafe tap else { return } // no Accessibility: nothing to do, AeroSpace still works
    addToEventTapThread(tap)
}

/// On the event tap thread: a click without a modifier, or a drag that is not ours, goes
/// through without waiting for the main thread.
private func mouseDragCallback(_: CGEventTapProxy, type: CGEventType, event: CGEvent, _: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let location = event.location, flags = event.flags // CGEvent is not Sendable
    switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = unsafe tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .leftMouseDown, .rightMouseDown:
            if flags.intersection(modifierMask).isEmpty { return Unmanaged.passUnretained(event) }
        default:
            if !mouseDragActive.withLock({ $0 }) { return Unmanaged.passUnretained(event) }
    }
    return onMainForTap { handleMouse(type, location, flags) } ? nil : Unmanaged.passUnretained(event)
}

/// Returns true when the event is consumed.
@MainActor
private func handleMouse(_ type: CGEventType, _ location: CGPoint, _ flags: CGEventFlags) -> Bool {
    switch type {
        case .leftMouseDown, .rightMouseDown:
            guard TrayMenuModel.shared.isEnabled,
                  let wanted = parseMouseModifier(config.mouseModifier),
                  mouseModifierMatches(flags, wanted: wanted),
                  let (window, rect) = managedWindow(at: location) else { return false }
            isMouseDragInProgress = true
            // before nativeFocus: its refresh session must not lay the window out under the cursor
            if case .tilingContainer = window.windowParentCases { currentlyManipulatedWithMouseWindowId = window.windowId }
            window.nativeFocus()
            mouseDrag = MouseDrag(window: window, resize: type == .rightMouseDown, startMouse: location, startRect: rect,
                                  fromLeft: location.x < rect.midX, fromTop: location.y < rect.midY, current: location)
            return true
        case .leftMouseDragged, .rightMouseDragged:
            guard var drag = mouseDrag else { return false }
            drag.current = location
            mouseDrag = drag
            dragTick()
            return true
        case .leftMouseUp, .rightMouseUp:
            guard let drag = mouseDrag else { return false }
            mouseDrag = nil
            trailingTask?.cancel()
            hideDropPreview()
            let running = feedbackTask
            Task { @MainActor in
                await running?.value
                defer { isMouseDragInProgress = false }
                guard TrayMenuModel.shared.isEnabled else { return }
                // the last drag events may have been skipped: catch up at the drop point
                applyDragFrame(drag)
                mouseDragDropLocation = drag.current
                if drag.window.isFloating {
                    try? await moveWithMouse(drag.window) // workspace of the monitor it is dropped on
                } else {
                    await liveStep(drag)
                }
                mouseDragDropLocation = nil
                // one complete refresh (normalize, layout) for the whole drag
                isMouseDragInProgress = false
                if currentlyManipulatedWithMouseWindowId != nil {
                    try? await resetManipulatedWithMouseIfPossible()
                } else {
                    scheduleCancellableCompleteRefreshSession(.ax("mouseDrag"))
                }
            }
            return true
        default:
            return false
    }
}

/// One throttled update: the window frame, then (if the previous one is done) the live layout.
@MainActor
private func dragTick() {
    guard var drag = mouseDrag else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard drag.throttle.fire(at: now) else {
        // keep the last cursor position: update once the interval is over
        if trailingTask == nil {
            let wait = drag.throttle.remaining(at: now)
            trailingTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(wait))
                trailingTask = nil
                if !Task.isCancelled { dragTick() }
            }
        }
        return
    }
    mouseDrag = drag
    applyDragFrame(drag)
    if feedbackTask != nil || !TrayMenuModel.shared.isEnabled || drag.window.isFloating { return }
    feedbackTask = Task { @MainActor in
        mouseDragDropLocation = drag.current
        await liveStep(drag)
        mouseDragDropLocation = nil
        feedbackTask = nil
    }
}

/// Live grid / live resize for the current cursor position.
@MainActor
private func liveStep(_ drag: MouseDrag) async {
    let window = drag.window
    guard case .tilingContainer = window.windowParentCases else { return }
    let before = window.nodeWorkspace
    var touched: [Workspace] = before.map { [$0] } ?? []
    if drag.resize {
        try? await resizeWithMouse(window)
    } else {
        let point = drag.current
        let workspace = point.monitorApproximation.activeWorkspace
        let found = point.findWindowRecursively(in: workspace.rootTilingContainer, virtual: false, fullscreenCoversAll: false)
        if found == nil || found == window { mouseDrag?.lastTarget = nil } // over its own slot (or no tile)
        guard let target = found, target != window, let targetRect = target.lastAppliedLayoutPhysicalRect,
              isDeepInside(point, targetRect.toCGRect()),
              dragTargetChanged(previous: mouseDrag?.lastTarget, new: target.windowId) else { return }
        mouseDrag?.lastTarget = target.windowId
        showDropPreview(targetRect.toCGRect())
        moveTilingWindow(window)
        touched.append(workspace)
        if window.nodeWorkspace != before { before?.normalizeContainers() }
    }
    for workspace in Set(touched) where workspace.isVisible {
        try? await workspace.layoutWorkspace()
    }
}

@MainActor
private func applyDragFrame(_ drag: MouseDrag) {
    let dx = drag.current.x - drag.startMouse.x, dy = drag.current.y - drag.startMouse.y
    let r = drag.startRect
    if drag.resize {
        let f = resizedDragFrame(start: r, dx: dx, dy: dy, fromLeft: drag.fromLeft, fromTop: drag.fromTop)
        drag.window.setAxFrame(f.origin, f.size)
    } else {
        drag.window.setAxFrame(CGPoint(x: r.minX + dx, y: r.minY + dy), nil)
    }
}

/// Topmost window managed by AeroSpace under `point` (global, top-left origin), with its frame.
@MainActor
func managedWindow(at point: CGPoint) -> (Window, CGRect)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    // Front to back. A window of an unmanaged app on the normal level hides what is below.
    for info in list where (info[kCGWindowOwnerPID as String] as? pid_t) != myPid {
        guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(point) else { continue }
        if let id = info[kCGWindowNumber as String] as? UInt32, let window = MacWindow.allWindowsMap[id] {
            return window.isHiddenInCorner ? nil : (window, rect)
        }
        if (info[kCGWindowLayer as String] as? Int) == 0 { return nil }
    }
    return nil
}
