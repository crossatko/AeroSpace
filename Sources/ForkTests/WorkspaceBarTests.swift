import CoreGraphics
import Testing
@testable import AppBundle

private func item(_ name: String, w: CGFloat = 10, short: CGFloat? = nil, empty: Bool = false, focused: Bool = false,
                  visible: Bool = false, monitor: Int = 0) -> WorkspaceBarItem
{
    WorkspaceBarItem(name: name, textWidth: w, shortTextWidth: short, isFocused: focused, isVisible: visible, isEmpty: empty, monitorIndex: monitor)
}

// padding 8 -> a pill with text width 10 is 26 wide; spacing 4, group gap 12
private func names(_ l: WorkspaceBarLayout) -> [String] { l.pills.map { $0.item.name } }

@Suite struct WorkspaceBarLayoutTests {
    @Test func pillsAreLaidOutLeftToRight() {
        let l = layoutWorkspaceBar([item("1"), item("2"), item("3")])
        #expect(l.pills.map { $0.x } == [0, 30, 60])
        #expect(l.pills.map { $0.width } == [26, 26, 26])
        #expect(l.totalWidth == 86)
    }

    @Test func hitTestFindsPillsAndGaps() {
        let l = layoutWorkspaceBar([item("1"), item("2"), item("3")])
        #expect(l.hitTest(x: 0) == "1")
        #expect(l.hitTest(x: 25.9) == "1")
        #expect(l.hitTest(x: 27) == "1") // gap, nearer to 1
        #expect(l.hitTest(x: 29) == "2") // gap, nearer to 2
        #expect(l.hitTest(x: 45) == "2")
        #expect(l.hitTest(x: 85) == "3")
        #expect(l.hitTest(x: -1) == nil)
        #expect(l.hitTest(x: 86) == nil)
    }

    @Test func widthsFollowTheText() {
        let l = layoutWorkspaceBar([item("1", w: 8), item("Mail", w: 30)])
        #expect(l.pills.map { $0.width } == [24, 46])
        #expect(l.hitTest(x: 40) == "Mail")
    }

    @Test func emptyWorkspacesAreHiddenUnlessVisibleOrFocused() {
        let l = layoutWorkspaceBar([
            item("1", empty: true), item("2"), item("3", empty: true, visible: true), item("4", empty: true, focused: true), item("5", empty: true),
        ])
        #expect(names(l) == ["2", "3", "4"])
        #expect(l.hiddenCount == 0)
    }

    @Test func monitorGroupsAreSeparatedAndSeparatorIsNotClickable() {
        let l = layoutWorkspaceBar([item("1", monitor: 0), item("3", monitor: 1), item("2", monitor: 0), item("4", monitor: 1)])
        #expect(names(l) == ["1", "2", "3", "4"]) // grouped, order kept inside a group
        #expect(l.pills.map { $0.x } == [0, 30, 68, 98])
        #expect(l.separators == [62])
        #expect(l.hitTest(x: 62) == nil)
        #expect(l.hitTest(x: 60) == nil) // past pill 2 and its slop, inside the group gap
        #expect(l.hitTest(x: 68) == "3")
    }

    @Test func overflowCompactsHiddenWorkspacesFirst() {
        let items = [
            item("1", w: 30, short: 10, focused: true, visible: true), item("2", w: 30, short: 10), item("3", w: 30, short: 10),
        ]
        var m = WorkspaceBarMetrics()
        m.maxWidth = 150 // full: 46 * 3 + 8 = 146 fits
        #expect(layoutWorkspaceBar(items, m).pills.map { $0.isCompact } == [false, false, false])
        m.maxWidth = 120 // 46 + 26 + 26 + 8 = 106 fits after compacting the non-visible ones
        let l = layoutWorkspaceBar(items, m)
        #expect(l.pills.map { $0.isCompact } == [false, true, true])
        #expect(l.totalWidth == 106)
        #expect(l.hiddenCount == 0)
    }

    @Test func overflowCompactsVisibleOnesBeforeDropping() {
        let items = [
            item("1", w: 30, short: 10, focused: true, visible: true), item("2", w: 30, short: 10, visible: true, monitor: 1),
        ]
        var m = WorkspaceBarMetrics()
        m.maxWidth = 70 // 46 + 46 + 12 = 104 -> 46 + 26 + 12 = 84 still too wide, kept anyway
        let l = layoutWorkspaceBar(items, m)
        #expect(l.pills.map { $0.isCompact } == [false, true])
        #expect(l.pills.count == 2) // visible workspaces are never dropped
    }

    @Test func overflowDropsFromTheEndButKeepsFocusedAndVisible() {
        var items: [WorkspaceBarItem] = []
        for i in 1 ... 6 {
            items.append(item(String(i), w: 10, short: 4, focused: i == 2, visible: i == 2 || i == 4))
        }
        var m = WorkspaceBarMetrics()
        m.maxWidth = 70 // all compact = 6 * 20 + 20 = 140 -> drop 6, 5, 3, 1 as needed
        let l = layoutWorkspaceBar(items, m)
        #expect(names(l).contains("2"))
        #expect(names(l).contains("4"))
        #expect(!names(l).contains("6"))
        #expect(l.hiddenCount == 6 - l.pills.count)
        #expect(l.hiddenCount > 0)
    }

    @Test func zeroMaxWidthMeansUnlimited() {
        let items = (1 ... 30).map { item(String($0), w: 20) }
        let l = layoutWorkspaceBar(items)
        #expect(l.pills.count == 30)
        #expect(l.pills.allSatisfy { !$0.isCompact })
    }

    @Test func emptyInput() {
        let l = layoutWorkspaceBar([item("1", empty: true)])
        #expect(l.pills.isEmpty)
        #expect(l.totalWidth == 0)
        #expect(l.hitTest(x: 0) == nil)
    }
}

@Suite struct ScrollSwitchTrackerTests {
    @Test func oneFlickSwitchesOnceDespiteMomentum() {
        var t = ScrollSwitchTracker()
        var out: [ScrollDirection] = []
        // finger phase, then momentum events every 16 ms for ~1 s
        for i in 0 ..< 60 {
            if let d = t.feed(delta: -3, at: Double(i) * 0.016, isPrecise: true, isGestureBegin: i == 0) { out.append(d) }
        }
        #expect(out == [.next])
    }

    @Test func nextFlickAfterAPauseSwitchesAgain() {
        var t = ScrollSwitchTracker()
        var out: [ScrollDirection] = []
        for i in 0 ..< 10 { if let d = t.feed(delta: -4, at: Double(i) * 0.016, isPrecise: true, isGestureBegin: i == 0) { out.append(d) } }
        for i in 0 ..< 10 { if let d = t.feed(delta: 4, at: 1.0 + Double(i) * 0.016, isPrecise: true) { out.append(d) } } // quiet gap, no begin phase
        #expect(out == [.next, .prev])
    }

    @Test func newGestureBeginUnlocks() {
        var t = ScrollSwitchTracker()
        #expect(t.feed(delta: 10, at: 0, isPrecise: true, isGestureBegin: true) == .prev)
        #expect(t.feed(delta: 10, at: 0.05, isPrecise: true) == nil)
        #expect(t.feed(delta: -10, at: 0.1, isPrecise: true, isGestureBegin: true) == .next)
    }

    @Test func smallScrollsBelowThresholdAreIgnored() {
        var t = ScrollSwitchTracker()
        #expect(t.feed(delta: 1, at: 0, isPrecise: true, isGestureBegin: true) == nil)
        #expect(t.feed(delta: 1, at: 0.02, isPrecise: true) == nil)
        #expect(t.feed(delta: 1, at: 0.04, isPrecise: true) == nil)
    }

    @Test func wheelSwitchesPerNotchRateLimited() {
        var t = ScrollSwitchTracker()
        #expect(t.feed(delta: 1, at: 0, isPrecise: false) == .prev)
        #expect(t.feed(delta: 1, at: 0.01, isPrecise: false) == nil)
        #expect(t.feed(delta: -1, at: 0.2, isPrecise: false) == .next)
    }
}

@Suite struct WorkspaceBarCoordinateTests {
    @Test func buttonXToBarX() {
        #expect(barLocalX(pointInButtonX: 30, barOriginX: 0) == 30)
        #expect(barLocalX(pointInButtonX: 30, barOriginX: 4) == 26)
        let l = layoutWorkspaceBar([item("1"), item("2")])
        #expect(l.hitTest(x: barLocalX(pointInButtonX: 34, barOriginX: 4)) == "2")
    }
}

@Suite struct StockMenuBarItemTests {
    private func visible(clickable: Bool = true, hide: Bool = true, ax: Bool = true, enabled: Bool = true, installed: Bool = true) -> Bool {
        stockMenuBarItemVisible(clickable: clickable, hideStock: hide, axGranted: ax, enabled: enabled, pillsInstalled: installed)
    }

    @Test func hiddenOnlyWhenPillsAreReallyShown() {
        #expect(!visible())
    }

    @Test func shownWheneverAnythingIsMissing() {
        #expect(visible(clickable: false))
        #expect(visible(hide: false))
        #expect(visible(ax: false))
        #expect(visible(enabled: false))
        #expect(visible(installed: false))
    }
}
