@testable import AppBundle
import Common
import XCTest

// Insertion logic and expected trees follow Skyland's DwindleTest (MIT)
@MainActor
final class DwindleTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testNewWindowSplitsFocusedWindow() async throws {
        config.dwindle = true
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        assertEquals(TestWindow.new(id: 2, parent: root).focusWindow(), true)

        let w3 = TestWindow.new(id: 3, parent: root)
        try await w3.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .window(1),
            .v_tiles([.window(2), .window(3)]),
        ]))

        assertEquals(w3.focusWindow(), true)
        let w4 = TestWindow.new(id: 4, parent: root)
        try await w4.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .window(1),
            .v_tiles([.window(2), .h_tiles([.window(3), .window(4)])]),
        ]))
    }

    func testDisabledKeepsUpstreamBehavior() async throws {
        config.dwindle = false
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        assertEquals(TestWindow.new(id: 2, parent: root).focusWindow(), true)
        let w3 = TestWindow.new(id: 3, parent: root)
        try await w3.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))
    }

    func testRectDecidesOrientation() async throws {
        config.dwindle = true
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let w1 = TestWindow.new(id: 1, parent: root)
        w1.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 800) // tall
        assertEquals(w1.focusWindow(), true)
        let w2 = TestWindow.new(id: 2, parent: root)
        try await w2.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .v_tiles([.window(1), .window(2)]))
    }

    func testAccordionParentIsUnaffected() async throws {
        config.dwindle = true
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        root.layout = .accordion
        TestWindow.new(id: 1, parent: root)
        assertEquals(TestWindow.new(id: 2, parent: root).focusWindow(), true)
        let w3 = TestWindow.new(id: 3, parent: root)
        try await w3.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_accordion([.window(1), .window(2), .window(3)]))
    }

    func testOppositeNormalizationSkippedWhenDwindle() {
        config.dwindle = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        TilingContainer.newHTiles(parent: root, adaptiveWeight: 1).apply {
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .window(1),
            .h_tiles([.window(2), .window(3)]),
        ]))
    }

    func testSplitHelper() {
        assertEquals(dwindleSplit(Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600), fallback: .v), .h)
        assertEquals(dwindleSplit(Rect(topLeftX: 0, topLeftY: 0, width: 600, height: 800), fallback: .h), .v)
        assertEquals(dwindleSplit(Rect(topLeftX: 0, topLeftY: 0, width: 700, height: 700), fallback: .v), .h)
        assertEquals(dwindleSplit(nil, fallback: .v), .v)
    }

    func testConfigKey() {
        assertEquals(parseConfig("dwindle = true").config.dwindle, true)
        assertEquals(parseConfig("").config.dwindle, false)
    }
}
