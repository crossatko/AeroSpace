@testable import AppBundle
import Foundation
import Testing

private let a = CGPoint(x: 100, y: 100) // inside tile 1
private let b = CGPoint(x: 700, y: 100) // inside tile 2
private let gap = CGPoint(x: 500, y: 100)

private func hit(_ p: CGPoint) -> FfmHit {
    // tile 1: x 0..495, tile 2: x 505..1000, 10 px gap between
    if p.x < 495 { return .tiling(1) }
    if p.x >= 505 { return .tiling(2) }
    return .none
}

private struct Driver {
    var s = FfmState()
    var focused: UInt32? = 1
    var now = 1000
    var focusCalls: [UInt32] = []

    mutating func move(_ p: CGPoint, dt: Int = 5) -> FfmDecision {
        now += dt
        let d = s.feed(.mouseMoved(p, hit: hit(p), focusedId: focused), nowMs: now)
        if case .focus(let h) = d, let id = h.windowId {
            focusCalls.append(id)
            focused = id
        }
        return d
    }
    mutating func feed(_ i: FfmInput, dt: Int = 5) -> FfmDecision {
        now += dt
        return s.feed(i, nowMs: now)
    }
}

@Suite struct FocusFollowsMouseDecisionTests {
    @Test func hoverSwitchesOnceAndNeverRefocuses() {
        var d = Driver()
        _ = d.move(a)
        #expect(d.move(b) == .focus(.tiling(2)))
        for x in stride(from: 700, to: 900, by: 10) { #expect(d.move(CGPoint(x: x, y: 100)) == .none) }
        #expect(d.focusCalls == [2])
    }

    @Test func alternatingAcrossTilesFollowsRealChangesOnly() {
        var d = Driver()
        // 3 real changes (b, a, b); repeated samples inside the same tile must not add any
        let seq = [a, a, b, b, b, a, a, b, b]
        for p in seq { _ = d.move(p) }
        #expect(d.focusCalls == [2, 1, 2])
    }

    @Test func gapIsIgnoredAndDoesNotCauseRefocus() {
        var d = Driver()
        _ = d.move(a)
        _ = d.move(b)
        #expect(d.move(gap) == .none)
        #expect(d.move(b) == .none) // back into the same target through the gap: no refocus
        #expect(d.focusCalls == [2])
    }

    @Test func noChangeWhileButtonHeld() {
        var d = Driver()
        _ = d.move(a)
        _ = d.feed(.mouseDown)
        #expect(d.move(b) == .none)
        #expect(d.focusCalls.isEmpty)
        _ = d.feed(.mouseUp)
        // cooldown right after release
        #expect(d.move(b, dt: 20) == .none)
        // after the cooldown the hover works again
        #expect(d.move(b, dt: 300) == .focus(.tiling(2)))
    }

    @Test func cooldownOnlyAfterMouseUp() {
        var d = Driver()
        _ = d.move(a)
        #expect(d.move(b, dt: 1) == .focus(.tiling(2))) // no click before: instant
    }

    @Test func mouseDownCancelsPending() {
        var d = Driver()
        d.s = FfmState(delayMs: 80)
        _ = d.move(a)
        #expect(d.move(b) == .scheduleFocus(.tiling(2), afterMs: 80))
        #expect(d.feed(.mouseDown) == .cancelPending)
        #expect(d.feed(.timerFired(windowId: 2)) == .cancelPending || d.focusCalls.isEmpty)
        #expect(d.focusCalls.isEmpty)
    }

    @Test func delayedFocusFiresOnlyIfCursorStayed() {
        var d = Driver()
        d.s = FfmState(delayMs: 80)
        _ = d.move(a)
        _ = d.move(b)
        #expect(d.move(a) == .cancelPending) // left before the dwell elapsed
        _ = d.move(b)
        #expect(d.feed(.timerFired(windowId: 2), dt: 90) == .focus(.tiling(2)))
    }

    @Test func foreignFocusChangeSuppressesUntilRealMovement() {
        var d = Driver()
        _ = d.move(a)
        _ = d.move(b) // hover focused 2
        d.focused = 1 // keyboard moved focus back, or a workspace switch
        #expect(d.move(CGPoint(x: 702, y: 100)) == .none) // jitter
        #expect(d.move(CGPoint(x: 704, y: 100)) == .none)
        // still inside the same hovered tile after real movement: current target, no steal
        #expect(d.move(CGPoint(x: 760, y: 100)) == .none)
        #expect(d.focusCalls == [2])
        // moving to the other tile works again
        #expect(d.move(a) == .none) // focused is 1 already
        #expect(d.move(b) == .focus(.tiling(2)))
    }

    @Test func workspaceSwitchUnderStillCursorDoesNotFocus() {
        var d = Driver()
        _ = d.move(a)
        d.focused = nil // switched to another workspace (empty or different window below the cursor)
        #expect(d.move(CGPoint(x: 101, y: 100)) == .none)
        #expect(d.move(CGPoint(x: 102, y: 101)) == .none)
        #expect(d.focusCalls.isEmpty)
    }

    @Test func hitTestFloatingOrderAndGaps() {
        let f1 = FfmFloating(windowId: 10, rect: CGRect(x: 0, y: 0, width: 200, height: 200))
        let f2 = FfmFloating(windowId: 11, rect: CGRect(x: 100, y: 100, width: 200, height: 200))
        let tile = CGRect(x: 0, y: 0, width: 495, height: 400)
        #expect(ffmHitTest(CGPoint(x: 150, y: 150), floatingTopFirst: [f2, f1], tilingId: 1, tilingRect: tile) == .floating(11))
        #expect(ffmHitTest(CGPoint(x: 150, y: 150), floatingTopFirst: [f1, f2], tilingId: 1, tilingRect: tile) == .floating(10))
        #expect(ffmHitTest(CGPoint(x: 400, y: 350), floatingTopFirst: [f1, f2], tilingId: 1, tilingRect: tile) == .tiling(1))
        #expect(ffmHitTest(CGPoint(x: 500, y: 350), floatingTopFirst: [], tilingId: 1, tilingRect: tile) == .none)
    }
}

@MainActor
@Suite struct FocusFollowsMouseConfigTests {
    @Test func modes() {
        func mode(_ toml: String) -> (FocusFollowsMouse, Int) {
            let r = parseConfig("config-version = 2\n" + toml)
            return (r.config.focusFollowsMouse, r.errors.count)
        }
        #expect(mode("").0.effectiveMode == .off)
        #expect(mode("focus-follows-mouse.enabled = true").0.effectiveMode == .raise)
        #expect(mode("focus-follows-mouse.mode = 'no-raise'").0.effectiveMode == .noRaise)
        #expect(mode("focus-follows-mouse = 'no-raise'").0.effectiveMode == .noRaise)
        #expect(mode("focus-follows-mouse.mode = 'bogus'").1 > 0)
        let m = mode("focus-follows-mouse.mode = 'no-raise'\nfocus-follows-mouse.delay-ms = 25\nfocus-follows-mouse.raise-apps = ['a.b']")
        #expect(m.0.delayMs == 25 && m.0.raiseApps == ["a.b"] && m.1 == 0)
        #expect(mode("").0.delayMs == 0)
    }
}
