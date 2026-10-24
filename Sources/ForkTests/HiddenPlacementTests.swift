@testable import AppBundle
import AppKit
import Common
import Testing

@Suite struct HiddenPlacementTests {
    // Built-in display, an external display above it
    let builtIn = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 800)
    let above = Rect(topLeftX: 0, topLeftY: -900, width: 1600, height: 900)

    func geometry(others: [Rect] = []) -> HiddenMonitorGeometry {
        HiddenMonitorGeometry(
            monitorRect: builtIn,
            visibleRect: Rect(topLeftX: 0, topLeftY: 30, width: 1000, height: 770),
            others: others,
        )
    }

    @Test func sideChoice() {
        let slots = hiddenSlots(workspaces: ["1", "2", "3", "4", "5", "6"], visible: "4", geometry: geometry())
        // Mission Control mirrors parked positions: lower workspaces park right, higher ones left
        #expect(slots["1"]?.edge == .right)
        #expect(slots["3"]?.edge == .right)
        #expect(slots["5"]?.edge == .left)
        #expect(slots["6"]?.edge == .left)
        #expect(slots["4"] == nil)
    }

    @Test func bandsKeepOrderNearestFirst() {
        let slots = hiddenSlots(workspaces: ["1", "2", "3", "4", "5", "6"], visible: "4", geometry: geometry())
        #expect(slots["3"]?.band == 0)
        #expect(slots["2"]?.band == 1)
        #expect(slots["1"]?.band == 2)
        #expect(slots["5"]?.band == 0)
        #expect(slots["6"]?.band == 1)
        #expect(slots["3"]?.bandCount == 3)
        #expect(slots["5"]?.bandCount == 2)
        // Vertical order of the parked windows follows the workspace distance
        let g = geometry()
        let y = { (n: String) in hiddenTarget(slot: slots[n]!, geometry: g, windowWidth: 500, relative: CGPoint(x: 0.5, y: 0.5), isZoom: false).y }
        #expect(y("3") < y("2"))
        #expect(y("2") < y("1"))
        #expect(y("5") < y("6"))
    }

    @Test func firstAndLastWorkspaceHaveOneSide() {
        let first = hiddenSlots(workspaces: ["1", "2", "3"], visible: "1", geometry: geometry())
        #expect(first.values.allSatisfy { $0.edge == .left })
        let last = hiddenSlots(workspaces: ["1", "2", "3"], visible: "3", geometry: geometry())
        #expect(last.values.allSatisfy { $0.edge == .right })
    }

    @Test func targetsStayOnTheEdgeWithOnePixelSliver() {
        let g = geometry()
        let left = HiddenSlot(edge: .left, isLowerSide: true, band: 0, bandCount: 1)
        let right = HiddenSlot(edge: .right, isLowerSide: false, band: 0, bandCount: 1)
        let l = hiddenTarget(slot: left, geometry: g, windowWidth: 400, relative: CGPoint(x: 0.2, y: 0.5), isZoom: false)
        let r = hiddenTarget(slot: right, geometry: g, windowWidth: 400, relative: CGPoint(x: 0.2, y: 0.5), isZoom: false)
        #expect(l.x == -399) // window spans -399...1, one pixel visible
        #expect(r.x == 999)
        // Never above the visible rect (menu bar), never below it
        for rel in [CGFloat(-3), 0, 0.5, 1, 7] {
            let p = hiddenTarget(slot: left, geometry: g, windowWidth: 400, relative: CGPoint(x: 0, y: rel), isZoom: false)
            #expect(p.y >= 30 && p.y <= 799)
        }
    }

    @Test func zoomGetsNoOffset() {
        let g = geometry()
        let left = HiddenSlot(edge: .left, isLowerSide: true, band: 0, bandCount: 1)
        let right = HiddenSlot(edge: .right, isLowerSide: false, band: 0, bandCount: 1)
        #expect(hiddenTarget(slot: left, geometry: g, windowWidth: 400, relative: .zero, isZoom: true).x == -400)
        #expect(hiddenTarget(slot: right, geometry: g, windowWidth: 400, relative: .zero, isZoom: true).x == 1000)
    }

    @Test func relativeLayoutInsideBandIsPreserved() {
        let g = geometry()
        let slot = HiddenSlot(edge: .right, isLowerSide: false, band: 1, bandCount: 2)
        let top = hiddenTarget(slot: slot, geometry: g, windowWidth: 300, relative: CGPoint(x: 0, y: 0.1), isZoom: false)
        let bottom = hiddenTarget(slot: slot, geometry: g, windowWidth: 300, relative: CGPoint(x: 0, y: 0.9), isZoom: false)
        #expect(top.y < bottom.y)
        // Band 1 of 2 is the lower half of the visible rect
        #expect(top.y >= 30 + 770 / 2)
    }

    @Test func neighbourBlocksEdges() {
        // Display to the left of the built-in one: left edge blocked
        let leftNeighbour = Rect(topLeftX: -1200, topLeftY: 0, width: 1200, height: 800)
        let g = geometry(others: [leftNeighbour])
        #expect(g.leftBlocked && !g.rightBlocked && !g.bottomBlocked)
        let slots = hiddenSlots(workspaces: ["1", "2", "3"], visible: "2", geometry: g)
        #expect(slots["3"]?.edge == .bottom) // higher workspaces want the left edge
        #expect(slots["1"]?.edge == .right)
    }

    @Test func displayAboveBlocksNothing() {
        let g = geometry(others: [above])
        #expect(!g.leftBlocked && !g.rightBlocked && !g.bottomBlocked)
    }

    @Test func displayBelowBlocksBottom() {
        let below = Rect(topLeftX: 0, topLeftY: 800, width: 1000, height: 600)
        #expect(geometry(others: [below]).bottomBlocked)
    }

    @Test func bottomFallbackSplitsLeftAndRightHalves() {
        let leftN = Rect(topLeftX: -1200, topLeftY: 0, width: 1200, height: 800)
        let rightN = Rect(topLeftX: 1000, topLeftY: 0, width: 1200, height: 800)
        let g = geometry(others: [leftN, rightN])
        let slots = hiddenSlots(workspaces: ["1", "2", "3", "4", "5"], visible: "3", geometry: g)
        #expect(slots.values.allSatisfy { $0.edge == .bottom })
        let x = { (n: String) in hiddenTarget(slot: slots[n]!, geometry: g, windowWidth: 300, relative: CGPoint(x: 0.5, y: 0), isZoom: false).x }
        // Mirrored: higher workspaces in the left half, lower in the right half, nearest next to the middle
        #expect(x("5") < x("4"))
        #expect(x("4") < x("2"))
        #expect(x("2") < x("1"))
        #expect(x("4") < 500 && x("2") >= 500)
        #expect(hiddenTarget(slot: slots["1"]!, geometry: g, windowWidth: 300, relative: .zero, isZoom: false).y == 799)
    }

    @Test func allEdgesBlockedFallsBackToCorner() {
        let leftN = Rect(topLeftX: -1200, topLeftY: 0, width: 1200, height: 800)
        let rightN = Rect(topLeftX: 1000, topLeftY: 0, width: 1200, height: 800)
        let below = Rect(topLeftX: 0, topLeftY: 800, width: 1000, height: 600)
        let g = geometry(others: [leftN, rightN, below])
        #expect(hiddenSlots(workspaces: ["1", "2", "3"], visible: "2", geometry: g).isEmpty)
        // One side usable, the other not
        let g2 = geometry(others: [leftN, below])
        let slots = hiddenSlots(workspaces: ["1", "2", "3"], visible: "2", geometry: g2)
        #expect(slots["3"] == nil)
        #expect(slots["1"]?.edge == .right)
    }

    @Test func unknownVisibleWorkspaceGivesNoSlots() {
        #expect(hiddenSlots(workspaces: ["1", "2"], visible: "9", geometry: geometry()).isEmpty)
    }

    @Test func targetIsDeterministic() {
        // Same input gives the exact same point, which is what lets the caller skip AX writes
        let g = geometry()
        let slot = HiddenSlot(edge: .left, isLowerSide: true, band: 2, bandCount: 3)
        let a = hiddenTarget(slot: slot, geometry: g, windowWidth: 640, relative: CGPoint(x: 0.3, y: 0.42), isZoom: false)
        let b = hiddenTarget(slot: slot, geometry: g, windowWidth: 640, relative: CGPoint(x: 0.3, y: 0.42), isZoom: false)
        #expect(a == b)
    }

    @MainActor @Test func configKey() {
        #expect(parseConfig("").config.hiddenWindowPlacement == .corner)
        #expect(parseConfig("hidden-window-placement = 'directional'").config.hiddenWindowPlacement == .directional)
        #expect(!parseConfig("hidden-window-placement = 'nope'").errors.isEmpty)
    }
}
