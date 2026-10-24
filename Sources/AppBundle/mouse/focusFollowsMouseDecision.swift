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
    /// `vetoed`: the glue found a reason not to change focus now (unmanaged front window, other window on top, menu...)
    case mouseMoved(CGPoint, hit: FfmHit, focusedId: UInt32?, vetoed: Bool = false)
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
    /// Why the last mouseMoved did nothing (diagnostics only)
    private(set) var lastDropReason: String? = nil
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
            case .mouseMoved(let point, let hit, let focusedId, let vetoed):
                return move(point, hit, focusedId, vetoed, nowMs)
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

    private mutating func move(_ point: CGPoint, _ hit: FfmHit, _ focusedId: UInt32?, _ vetoed: Bool, _ nowMs: Int) -> FfmDecision {
        defer { lastPoint = point }
        lastDropReason = nil
        // Foreign focus change (keyboard, workspace switch, click): wait for real movement
        if let seen = lastSeenFocused, seen != focusedId {
            suppressAnchor = lastPoint ?? point
        }
        lastSeenFocused = .some(focusedId)
        if let anchor = suppressAnchor {
            if hypot(point.x - anchor.x, point.y - anchor.y) < realMovementPx { lastDropReason = "suppressed-until-real-movement"; return dropPending() }
            suppressAnchor = nil
        }
        if buttonDown { lastDropReason = "button-held"; return dropPending() }

        guard let id = hit.windowId else { lastDropReason = "no-hit"; return dropPending() } // gap / nothing: no change
        if id == lastTarget { lastDropReason = "same-as-last-target"; return dropPending() } // never refocus the current target
        if id == focusedId {
            lastTarget = id
            lastDropReason = "already-focused"
            return dropPending()
        }
        if vetoed { lastDropReason = "vetoed"; return dropPending() }
        if isBlocked(nowMs: nowMs) { lastDropReason = "blocked(button/suppressed/cooldown)"; return dropPending() }
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

// MARK: vetoes (only ever veto a target chosen from AeroSpace's layout; they never pick one)

struct FfmWindowInfo: Equatable {
    let id: UInt32
    let pid: Int32
    let layer: Int
    let alpha: Double
    let bounds: CGRect
}

/// Layers that count as "something covers the cursor". Measured on macOS 26: normal windows 0, Dock/Mission Control
/// and floating/modal/status panels (Spotlight, Raycast, 1Password) 1...23, menubar "Window Server" 24 and status
/// items 25 (the menu bar is outside every tile anyway, so they are skipped), screen-saver/overlay levels above.
/// Negative layers are the always-present desktop plumbing (wallpaper, event shield, backstops) and never count.
func ffmLayerCounts(_ layer: Int) -> Bool {
    (0 ... 23).contains(layer) || layer > 25
}

/// True if a window that is not the target covers the cursor. `windowsFrontToBack` is the window server order.
/// Windows with alpha ~0 and AeroSpace's own windows are ignored. Another layer-0 window of the target's own app
/// does not veto (apps keep invisible twin windows, e.g. browser tab groups, with identical frames).
/// `raisesTarget`: the target is a floating window that is about to be raised. A layer-0 window that AeroSpace manages
/// (`isManaged`) and that sits above it is then no veto: it only got above the floating window by a click/raise, and
/// raising the target is exactly what puts the stacking right again. Without this, one click on a tiled window
/// above a floating one would block hover-focus of the floating window for good. Panels, overlays (layer > 0) and
/// unmanaged windows still veto.
func ffmTopmostVeto(
    _ point: CGPoint, targetId: UInt32, targetPid: Int32, windowsFrontToBack: [FfmWindowInfo], ownPid: Int32,
    raisesTarget: Bool = false, isManaged: (UInt32) -> Bool = { _ in false },
) -> Bool {
    for w in windowsFrontToBack {
        guard ffmLayerCounts(w.layer), w.alpha > 0.01, w.pid != ownPid, w.bounds.contains(point) else { continue }
        if w.id == targetId { return false }
        if w.pid == targetPid && w.layer == 0 { return false }
        if raisesTarget && w.layer == 0 && isManaged(w.id) { continue }
        return true
    }
    return false
}

/// True if the focused window of the focused app exists but AeroSpace does not manage it (launcher panel, dialog,
/// password popup). A missing focused window (app without windows) does not veto.
func ffmUnmanagedFrontVeto(focusedWindowId: UInt32?, isManaged: (UInt32) -> Bool) -> Bool {
    guard let id = focusedWindowId else { return false }
    return !isManaged(id)
}

/// Raise policy of no-raise mode: only explicit raise-apps raise. Neither tiled nor floating targets do (a hovered
/// floating window must not come over the previously focused one), not when SkyLight is unavailable and not when
/// no-raise failed to verify for the app (both are only logged).
func ffmShouldRaise(hit: FfmHit, inRaiseApps: Bool) -> Bool {
    inRaiseApps
}

/// Orders floating candidates by the real window server stacking (front to back). Ids missing from the z-order go
/// last, keeping their relative (MRU) order. Floating windows no longer raise on hover, so MRU order cannot be trusted.
func ffmOrderFloatingByZ(_ candidates: [FfmFloating], zOrderFrontToBack: [UInt32]) -> [FfmFloating] {
    let rank = Dictionary(zOrderFrontToBack.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    return candidates.enumerated().sorted { a, b in
        let ra = rank[a.element.windowId] ?? Int.max, rb = rank[b.element.windowId] ?? Int.max
        return ra != rb ? ra < rb : a.offset < b.offset
    }.map(\.element)
}


// MARK: AX element under the cursor (menus and popups veto; hosted content of the target does not)

struct FfmAxElementInfo: Equatable, Sendable {
    let role: String?
    let subrole: String?
    let pid: Int32
    /// The element has a top-level AXWindow (or is one)
    let hasWindow: Bool
    let frame: CGRect?
}

/// Roles of menus, popups and other transient surfaces: always a veto
func ffmAxRoleIsTransient(_ role: String?) -> Bool {
    ["AXMenu", "AXMenuItem", "AXMenuBar", "AXMenuBarItem", "AXMenuButton", "AXPopover", "AXSheet", "AXDrawer", "AXPopUpButton"].contains(role ?? "")
}

/// True if the AX element under the cursor means "do not switch focus" (a menu/popup is open under the cursor).
/// Elements without an AXWindow used to veto unconditionally. Remote-view content (System Settings panes are hosted by
/// extension processes) has none, and its scroll group can be taller than the window, so the element frame is not
/// required to lie inside the target. Instead: the cursor must lie inside the target frame (the hit-test chose the
/// target by frame) and the element must intersect it. Any owner pid is accepted: hosted content belongs to another
/// process by design, and genuine menus/popovers/sheets are caught by their roles.
func ffmAxElementVeto(_ e: FfmAxElementInfo, cursor: CGPoint, targetFrame: CGRect?, tolerance: CGFloat = 4) -> Bool {
    if ffmAxRoleIsTransient(e.role) { return true }
    if e.hasWindow || e.role == "AXWindow" { return false }
    guard let t = targetFrame?.insetBy(dx: -tolerance, dy: -tolerance), let f = e.frame, t.contains(cursor), t.intersects(f) else { return true }
    return false
}
