import Foundation

// Pure decision layer of focus-follows-mouse. No AppKit, no AX, no tree access: the glue in
// focusFollowsMouse.swift resolves the window under the cursor from AeroSpace's OWN layout and feeds it here.
//
// Why it is built like this (AutoFocus-style flicker and eaten clicks):
// - The hit-test never looks at window server z-order, so a focus change (which can reorder things in no-raise
//   mode) cannot change the answer for the same cursor position: no feedback loop.
// - A window is only focused when the cursor enters a DIFFERENT window than the last hovered one.
// - Gaps and non-window areas give no hit and never change anything.
// - Nothing happens while a mouse button is held, a mouse-down cancels a pending change, and the first
//   `clickCooldownMs` after a button release are ignored (focus action only).
// - Focus changes made by anyone else (keyboard, workspace switch) suppress the feature until the mouse really moves.

struct FfmFloating: Equatable {
    let windowId: UInt32
    let rect: CGRect
}

enum FfmHit: Equatable {
    case none
    case tiling(UInt32)
    case floating(UInt32)

    var windowId: UInt32? {
        switch self {
            case .none: nil
            case .tiling(let id), .floating(let id): id
        }
    }
}

/// `floatingTopFirst`: floating windows in AeroSpace's MRU order (most recent = assumed topmost).
/// `tiling`: the tiling window found by AeroSpace's layout, with its rect (nil rect = unknown).
func ffmHitTest(_ point: CGPoint, floatingTopFirst: [FfmFloating], tilingId: UInt32?, tilingRect: CGRect?) -> FfmHit {
    if let f = floatingTopFirst.first(where: { $0.rect.contains(point) }) { return .floating(f.windowId) }
    // The tiling rect is the window itself (inner gaps already cut out), so the gap between tiles is no hit
    if let tilingId, let tilingRect, tilingRect.contains(point) { return .tiling(tilingId) }
    return .none
}

enum FfmInput {
    case mouseMoved(CGPoint, hit: FfmHit, focusedId: UInt32?)
    case mouseDown
    case mouseUp
    /// The dwell timer for `windowId` elapsed (only with delay-ms > 0)
    case timerFired(windowId: UInt32)
}

enum FfmDecision: Equatable {
    case none
    case focus(FfmHit)
    case scheduleFocus(FfmHit, afterMs: Int)
    case cancelPending
}

struct FfmState {
    var delayMs: Int = 0
    var clickCooldownMs: Int = 150
    /// Cursor movement needed after a foreign focus change before the feature acts again
    var realMovementPx: CGFloat = 8

    private(set) var lastTarget: UInt32? = nil
    private(set) var pending: FfmHit? = nil
    private var buttonDown = false
    private var lastMouseUpMs: Int? = nil
    private var lastPoint: CGPoint? = nil
    private var lastSeenFocused: UInt32?? = .none // .none = never seen
    private var suppressAnchor: CGPoint? = nil
    private var previousLastTarget: UInt32? = nil

    init(delayMs: Int = 0) { self.delayMs = delayMs }

    /// Cheap pre-check for the glue: would a move to `hit` lead to a focus change? (Used to run the expensive
    /// AX menu/popup veto only when needed.)
    func wouldAct(_ hit: FfmHit, focusedId: UInt32?, nowMs: Int) -> Bool {
        guard let id = hit.windowId, id != lastTarget, id != focusedId else { return false }
        return !isBlocked(nowMs: nowMs)
    }

    /// Undo the "last target" bookkeeping when the glue vetoed/cancelled a decision it got (menu under cursor etc.)
    mutating func revertLastDecision() {
        lastTarget = previousLastTarget
    }

    mutating func feed(_ input: FfmInput, nowMs: Int) -> FfmDecision {
        switch input {
            case .mouseDown:
                buttonDown = true
                return dropPending()
            case .mouseUp:
                buttonDown = false
                lastMouseUpMs = nowMs
                return .none
            case .timerFired(let id):
                guard let p = pending, p.windowId == id, !isBlocked(nowMs: nowMs) else { return dropPending() }
                pending = nil
                previousLastTarget = lastTarget
                lastTarget = id
                lastSeenFocused = .some(id)
                return .focus(p)
            case .mouseMoved(let point, let hit, let focusedId):
                return move(point, hit, focusedId, nowMs)
        }
    }

    private func isBlocked(nowMs: Int) -> Bool {
        if buttonDown || suppressAnchor != nil { return true }
        if let up = lastMouseUpMs, nowMs - up < clickCooldownMs { return true }
        return false
    }

    private mutating func dropPending() -> FfmDecision {
        defer { pending = nil }
        return pending == nil ? .none : .cancelPending
    }

    private mutating func move(_ point: CGPoint, _ hit: FfmHit, _ focusedId: UInt32?, _ nowMs: Int) -> FfmDecision {
        defer { lastPoint = point }
        // Foreign focus change (keyboard, workspace switch, click): wait for real movement
        if let seen = lastSeenFocused, seen != focusedId {
            suppressAnchor = lastPoint ?? point
        }
        lastSeenFocused = .some(focusedId)
        if let anchor = suppressAnchor {
            if hypot(point.x - anchor.x, point.y - anchor.y) < realMovementPx { return dropPending() }
            suppressAnchor = nil
        }
        if buttonDown { return dropPending() }

        guard let id = hit.windowId else { return dropPending() } // gap / nothing: no change
        if id == lastTarget { return dropPending() } // never refocus the current target
        if id == focusedId {
            lastTarget = id
            return dropPending()
        }
        if isBlocked(nowMs: nowMs) { return dropPending() }
        if pending?.windowId == id { return .none }
        pending = nil
        if delayMs > 0 {
            pending = hit
            return .scheduleFocus(hit, afterMs: delayMs)
        }
        previousLastTarget = lastTarget
        lastTarget = id
        lastSeenFocused = .some(id) // our own change is not a foreign one
        return .focus(hit)
    }
}
