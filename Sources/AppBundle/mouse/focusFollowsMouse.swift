import AppKit
import Common

// Glue between NSEvent and the pure decision layer (focusFollowsMouseDecision.swift).
// Modes: raise = upstream behaviour (focus + AXRaise), no-raise = SkyLight focus without changing the stacking order.

@MainActor private var focusFollowsMouseMonitor: Any? = nil
@MainActor private var focusFollowsMouseConfig: (FocusFollowsMouseMode, Int, [String])? = nil
@MainActor private var focusFollowsTask: Task<(), any Error>? = nil
@MainActor private var focusFollowsTimer: Task<(), any Error>? = nil
@MainActor private var ffmDebugLogEnabled = false
@MainActor private var lastLoggedHit: FfmHit? = nil
@MainActor private var ffmState = FfmState()
/// Apps for which no-raise did not verify: they use raise from now on (until AeroSpace restarts)
@MainActor private var noRaiseFailedApps: Set<String> = []
@MainActor private var noRaiseUnavailableLogged = false
/// Last positive veto (target id, time): re-used for 100 ms so a panel left open costs one probe per 100 ms, not per move
@MainActor private var lastVeto: (id: UInt32, ms: Int)? = nil

private let ffmMonitoredEvents: NSEvent.EventTypeMask = [
    .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
]

@MainActor func syncFocusFollowsMouse(_ config: Config) {
    let ffm = config.focusFollowsMouse
    ffmDebugLogEnabled = ffm.debugLog
    let wanted: (FocusFollowsMouseMode, Int, [String])? = ffm.effectiveMode == .off ? nil : (ffm.effectiveMode, ffm.delayMs, ffm.raiseApps)
    if wanted?.0 == focusFollowsMouseConfig?.0 && wanted?.1 == focusFollowsMouseConfig?.1 && wanted?.2 == focusFollowsMouseConfig?.2 {
        return
    }
    if let monitor = focusFollowsMouseMonitor {
        NSEvent.removeMonitor(monitor)
        focusFollowsMouseMonitor = nil
    }
    focusFollowsTask?.cancel()
    focusFollowsTask = nil
    focusFollowsTimer?.cancel()
    focusFollowsTimer = nil
    focusFollowsMouseConfig = wanted
    guard let (_, delayMs, _) = wanted else { return }
    ffmState = FfmState(delayMs: delayMs)

    // Global monitors do not fire for our own app's events, which is fine. Button events are needed for the
    // "no focus change while a button is held" and "mouse-down cancels" rules (the old code relied on
    // mouseMoved not firing during drags).
    focusFollowsMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: ffmMonitoredEvents) { @MainActor event in
        let now = Int(ProcessInfo.processInfo.systemUptime * 1000)
        switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                focusFollowsTask?.cancel() // an in-flight hit-test must not turn into a focus change after the click
                applyDecision(ffmState.feed(.mouseDown, nowMs: now))
            case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                _ = ffmState.feed(.mouseUp, nowMs: now)
            default:
                let location = event.locationInWindow.withYAxisFlipped
                if NSEvent.pressedMouseButtons != 0 {
                    _ = ffmState.feed(.mouseDown, nowMs: now) // missed the down event (e.g. started outside)
                    return
                }
                focusFollowsTask?.cancel()
                focusFollowsTask = Task.startUnstructured { @MainActor in
                    guard let token: RunSessionGuard = .isServerEnabled else { return }
                    try checkCancellation()
                    let hit = try await ffmHitTestInLayout(location)
                    try checkCancellation()
                    let focusedId = focus.windowOrNil?.windowId
                    let now = Int(ProcessInfo.processInfo.systemUptime * 1000)
                    var vetoed = false
                    // Menus/popups are vetoed via AX, but only when we are about to act (AX is slow)
                    if ffmState.wouldAct(hit, focusedId: focusedId, nowMs: now) {
                        // Ignores macOS menubar dropdown, but not non-native menu-like fake windows
                        if await isAxWindowUnderMouse(location) == false { return }
                        try checkCancellation()
                        vetoed = await ffmVetoed(location, hit, now)
                        try checkCancellation()
                    }
                    let decision = ffmState.feed(.mouseMoved(location, hit: hit, focusedId: focusedId, vetoed: vetoed), nowMs: now)
                    if ffmDebugLogEnabled { ffmLogDecision(location, hit, focusedId, decision, vetoed) }
                    applyDecision(decision, token: token)
                }
        }
    }
}

@MainActor private func applyDecision(_ decision: FfmDecision, token: RunSessionGuard? = nil) {
    switch decision {
        case .none: break
        case .cancelPending:
            focusFollowsTimer?.cancel()
            focusFollowsTimer = nil
        case .scheduleFocus(let hit, let afterMs):
            focusFollowsTimer?.cancel()
            focusFollowsTimer = Task.startUnstructured { @MainActor in
                try await Task.sleep(for: .milliseconds(afterMs))
                guard let token: RunSessionGuard = .isServerEnabled else { return }
                let now = Int(ProcessInfo.processInfo.systemUptime * 1000)
                if case .focus(let h) = ffmState.feed(.timerFired(windowId: hit.windowId.orDie()), nowMs: now) {
                    await focusWindowFollowingMouse(h, token)
                }
            }
        case .focus(let hit):
            focusFollowsTimer?.cancel()
            focusFollowsTimer = nil
            guard let token = token ?? .isServerEnabled else { return }
            Task.startUnstructured { @MainActor in await focusWindowFollowingMouse(hit, token) }
    }
}

@MainActor private func focusWindowFollowingMouse(_ hit: FfmHit, _ token: RunSessionGuard) async {
    guard let id = hit.windowId, let window = Window.get(byId: id) else { return }
    guard let mode = focusFollowsMouseConfig?.0 else { return }
    let raiseApps = focusFollowsMouseConfig?.2 ?? []
    let bundleId = window.app.rawAppBundleId ?? ""
    var useRaise = mode == .raise
    if mode == .noRaise {
        // Floating windows raise, tiling ones never do (see ffmShouldRaise)
        useRaise = ffmShouldRaise(hit: hit, inRaiseApps: raiseApps.contains(bundleId))
        if !isNoRaiseFocusAvailable, !noRaiseUnavailableLogged {
            noRaiseUnavailableLogged = true
            eprint("focus-follows-mouse: SkyLight symbols for no-raise are missing on this macOS, tiled windows get AeroSpace focus only")
        }
    }
    try? await runLightSession(.focusFollowsMouse, token) {
        _ = window.focusWindow()
        if useRaise {
            window.nativeFocus()
        }
    }
    if useRaise || !isNoRaiseFocusAvailable { return }
    guard let macWindow = window as? MacWindow else { return }
    let pid = macWindow.macApp.nsApp.processIdentifier
    let ok = await noRaiseFocusAndVerify(pid: pid, windowId: id)
    if !ok {
        // Never raise a tiled window as a fallback
        if noRaiseFailedApps.insert(bundleId).inserted {
            eprint("focus-follows-mouse: no-raise focus did not verify for '\(bundleId)', leaving the window unraised")
        }
        if ffmDebugLogEnabled { ffmLog("NORAISE-VERIFY-FAILED window=\(id) \(ffmDescribe(id)) bundle=\(bundleId)") }
    }
}

@concurrent
private nonisolated func noRaiseFocusAndVerify(pid: pid_t, windowId: UInt32) async -> Bool {
    focusWindowWithoutRaise(pid: pid, windowId: windowId) && verifyNoRaiseFocus(pid: pid, windowId: windowId)
}

/// Hit-test on AeroSpace's own layout: floating windows by MRU order (AX rect), tiling windows by the rects of the
/// last applied layout. Window server z-order is never consulted, so focus changes cannot change the answer.
@MainActor private func ffmHitTestInLayout(_ location: CGPoint) async throws -> FfmHit {
    let workspace = location.monitorApproximation.activeWorkspace
    var floating: [FfmFloating] = []
    for child in workspace.floatingWindowsContainer.mruChildren {
        try checkCancellation()
        guard let child = child as? Window else { continue }
        guard let rect = try await child.getAxRect(.cancellable) else { continue }
        floating.append(FfmFloating(windowId: child.windowId, rect: CGRect(x: rect.topLeftX, y: rect.topLeftY, width: rect.width, height: rect.height)))
    }
    let tiling = location.findWindowRecursively(in: workspace.rootTilingContainer, virtual: false, fullscreenCoversAll: true)
    let r = tiling?.lastAppliedLayoutPhysicalRect
    let tilingRect = r.map { CGRect(x: $0.topLeftX, y: $0.topLeftY, width: $0.width, height: $0.height) }
    let result = ffmHitTest(location, floatingTopFirst: floating, tilingId: tiling?.windowId, tilingRect: tilingRect)
    if ffmDebugLogEnabled, result != lastLoggedHit {
        lastLoggedHit = result
        let cands = floating.map { "\($0.windowId)@\(ffmRect($0.rect))" }.joined(separator: ",")
        ffmLog("HIT cursor=\(ffmPt(location)) workspace=\(workspace.name) result=\(result) floating=[\(cands)] tiling=\(tiling.map { "\($0.windowId)@\(tilingRect.map(ffmRect) ?? "?")" } ?? "none")")
    }
    return result
}

@concurrent
private nonisolated func isAxWindowUnderMouse(_ location: CGPoint) async -> Bool? {
    let systemwide = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    if unsafe AXUIElementCopyElementAtPosition(systemwide, Float(location.x), Float(location.y), &element) != .success {
        return nil
    }
    guard let element else { return nil }
    return element.get(Ax.parentWindowRecursive) != nil || element.get(Ax.roleAttr) == kAXWindowRole
}

/// Veto checks, run only when a focus change is about to happen (once per real target change; at most every 100 ms
/// while a veto holds). Both only ever veto, the target always comes from AeroSpace's layout.
///  1. An unmanaged window has focus (Raycast/Spotlight panel, dialog, password popup): pause.
///  2. The window server's topmost relevant window at the cursor is not the target (overlay, panel, Mission Control).
@MainActor private func ffmVetoed(_ location: CGPoint, _ hit: FfmHit, _ nowMs: Int) async -> Bool {
    guard let targetId = hit.windowId, let target = Window.get(byId: targetId) as? MacWindow else { return false }
    if let v = lastVeto, v.id == targetId, nowMs - v.ms < 100 {
        if ffmDebugLogEnabled { ffmLog("VETO(cached) cursor=\(ffmPt(location)) target=\(targetId) \(ffmDescribe(targetId))") }
        return true
    }
    let targetPid = target.macApp.nsApp.processIdentifier
    let isFloatingTarget: Bool = if case .floating = hit { true } else { false }
    let probe = await ffmProbe(location)
    let vetoed = ffmUnmanagedFrontVeto(focusedWindowId: probe.focusedWindowId) { Window.get(byId: $0) != nil }
        || ffmTopmostVeto(location, targetId: targetId, targetPid: targetPid, windowsFrontToBack: probe.windows, ownPid: ProcessInfo.processInfo.processIdentifier,
            raisesTarget: isFloatingTarget, isManaged: { Window.get(byId: $0) != nil })
    lastVeto = vetoed ? (targetId, nowMs) : nil
    if vetoed && ffmDebugLogEnabled { ffmLogVeto(location, targetId, targetPid, probe) }
    return vetoed
}

private struct FfmProbe: Sendable {
    let focusedWindowId: UInt32?
    let windows: [FfmWindowInfo]
    var focusedPid: Int32? = nil
}

@concurrent
private nonisolated func ffmProbe(_ location: CGPoint) async -> FfmProbe {
    // Focused window of the system-wide focused app (also right for non-activating panels such as Raycast)
    var focusedId: UInt32? = nil
    var focusedPid: Int32? = nil
    let systemwide = AXUIElementCreateSystemWide()
    var app: CFTypeRef?
    if unsafe AXUIElementCopyAttributeValue(systemwide, kAXFocusedApplicationAttribute as CFString, &app) == .success,
       let app, CFGetTypeID(app) == AXUIElementGetTypeID()
    {
        var pid: pid_t = 0
        if unsafe AXUIElementGetPid(app as! AXUIElement, &pid) == .success {
            focusedId = axFocusedWindowId(pid: pid)
            focusedPid = pid
        }
    }
    var windows: [FfmWindowInfo] = []
    let raw = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? [] // front to back
    for w in raw {
        var rect = CGRect.zero
        guard let b = w[kCGWindowBounds as String] as! CFDictionary?, CGRectMakeWithDictionaryRepresentation(b, &rect),
              rect.contains(location) // only windows under the cursor matter
        else { continue }
        windows.append(FfmWindowInfo(
            id: (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0,
            pid: (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
            layer: (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
            alpha: (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
            bounds: rect,
        ))
    }
    return FfmProbe(focusedWindowId: focusedId, windows: windows, focusedPid: focusedPid)
}


// MARK: debug log (focus-follows-mouse.debug-log = true): one line per decision, never per mouse move

@MainActor private func ffmDescribe(_ id: UInt32) -> String {
    guard let w = Window.get(byId: id) else { return "app=? unmanaged" }
    let kind = w.isFloating ? "floating" : "tiled"
    return "app=\((w as? MacWindow)?.macApp.nsApp.localizedName ?? "?") \(kind)"
}

private func ffmRect(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))" }

private func ffmPt(_ p: CGPoint) -> String { "\(Int(p.x)),\(Int(p.y))" }

@MainActor private func ffmLogDecision(_ location: CGPoint, _ hit: FfmHit, _ focusedId: UInt32?, _ decision: FfmDecision, _ vetoed: Bool) {
    let what: String
    switch decision {
        case .focus: what = "FOCUS"
        case .scheduleFocus(_, let ms): what = "SCHEDULE(\(ms)ms)"
        case .none, .cancelPending:
            guard vetoed else { return } // quiet unless a veto was the reason
            what = "VETOED-DECISION"
    }
    let target = hit.windowId.map { "\($0) \(ffmDescribe($0))" } ?? "none"
    let focused = focusedId.map { "\($0) \(ffmDescribe($0))" } ?? "none"
    ffmLog("\(what) cursor=\(ffmPt(location)) target=\(target) focused=\(focused)")
}

@MainActor private func ffmLogVeto(_ location: CGPoint, _ targetId: UInt32, _ targetPid: Int32, _ probe: FfmProbe) {
    let head = "VETO cursor=\(ffmPt(location)) target=\(targetId) \(ffmDescribe(targetId)) targetPid=\(targetPid)"
    if ffmUnmanagedFrontVeto(focusedWindowId: probe.focusedWindowId, isManaged: { Window.get(byId: $0) != nil }), let f = probe.focusedWindowId {
        ffmLog("\(head) guard=unmanaged-front focused=\(f) owner=\(ffmOwnerName(pid: probe.focusedPid ?? 0))")
        return
    }
    let own = ProcessInfo.processInfo.processIdentifier
    for w in probe.windows where ffmLayerCounts(w.layer) && w.alpha > 0.01 && w.pid != own {
        if w.id == targetId || (w.pid == targetPid && w.layer == 0) { break }
        let b = w.bounds
        ffmLog("\(head) guard=topmost cover=\(w.id) pid=\(w.pid) owner=\(ffmOwnerName(pid: w.pid)) layer=\(w.layer) alpha=\(w.alpha) bounds=\(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height)) managed=\(Window.get(byId: w.id) != nil)")
        return
    }
    ffmLog("\(head) guard=unknown")
}

private func ffmOwnerName(pid: Int32) -> String {
    NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
}

private let ffmLogMaxBytes = 1_000_000

@MainActor private func ffmLog(_ message: String) {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AeroSpace")
    let url = dir.appendingPathComponent("ffm.log")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > ffmLogMaxBytes {
        try? FileManager.default.removeItem(at: url) // cap: start over
    }
    let line = "\(Date().formatted(.iso8601.dateSeparator(.dash).timeSeparator(.colon).timeZone(separator: .omitted))) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: url) {
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    } else {
        try? data.write(to: url)
    }
}
