@testable import AppBundle
import CoreGraphics
import Testing

@Suite struct MouseDragTests {
    @Test func parsesModifiers() {
        #expect(parseMouseModifier("") == nil)
        #expect(parseMouseModifier("alt") == .maskAlternate)
        #expect(parseMouseModifier("option") == .maskAlternate)
        #expect(parseMouseModifier("cmd") == .maskCommand)
        #expect(parseMouseModifier("ctrl-alt") == [.maskControl, .maskAlternate])
        #expect(parseMouseModifier("super") == nil)
        #expect(parseMouseModifier("alt-bogus") == nil)
    }

    @Test func exactMatchOnly() {
        let alt: CGEventFlags = .maskAlternate
        #expect(mouseModifierMatches([.maskAlternate], wanted: alt))
        #expect(!mouseModifierMatches([.maskAlternate, .maskShift], wanted: alt))
        #expect(!mouseModifierMatches([], wanted: alt))
        #expect(!mouseModifierMatches([.maskCommand], wanted: alt))
        #expect(!mouseModifierMatches([], wanted: []))
        // non-modifier flags (caps lock, device bits) are ignored
        #expect(mouseModifierMatches([.maskAlternate, .maskAlphaShift], wanted: alt))
        #expect(mouseModifierMatches([.maskControl, .maskAlternate], wanted: [.maskControl, .maskAlternate]))
        #expect(!mouseModifierMatches([.maskAlternate], wanted: [.maskControl, .maskAlternate]))
    }

    @Test func resizeFromBottomRightGrows() {
        let r = resizedDragFrame(start: CGRect(x: 100, y: 100, width: 400, height: 300), dx: 50, dy: 20, fromLeft: false, fromTop: false)
        #expect(r == CGRect(x: 100, y: 100, width: 450, height: 320))
    }

    @Test func resizeFromTopLeftKeepsOppositeCorner() {
        let r = resizedDragFrame(start: CGRect(x: 100, y: 100, width: 400, height: 300), dx: -50, dy: -20, fromLeft: true, fromTop: true)
        #expect(r == CGRect(x: 50, y: 80, width: 450, height: 320))
    }

    @Test func resizeClampsToMinSize() {
        let r = resizedDragFrame(start: CGRect(x: 100, y: 100, width: 400, height: 300), dx: -1000, dy: -1000, fromLeft: false, fromTop: false)
        #expect(r.size == CGSize(width: 120, height: 120))
        let l = resizedDragFrame(start: CGRect(x: 100, y: 100, width: 400, height: 300), dx: 1000, dy: 1000, fromLeft: true, fromTop: true)
        #expect(l.maxX == 500 && l.maxY == 400 && l.width == 120)
    }
}

@Suite struct MouseDragLiveTests {
    @Test func throttleFiresAtMostOncePerInterval() {
        var t = DragThrottle(interval: 0.02)
        let a = t.fire(at: 100), b = t.fire(at: 100.005), c = t.fire(at: 100.019), d = t.fire(at: 100.021)
        #expect(a)
        #expect(!b)
        #expect(!c)
        #expect(d)
    }

    @Test func throttleRemainingForTrailingUpdate() {
        var t = DragThrottle(interval: 0.02)
        #expect(t.remaining(at: 5) == 0)
        _ = t.fire(at: 5)
        #expect(abs(t.remaining(at: 5.005) - 0.015) < 1e-9)
        #expect(t.remaining(at: 6) == 0)
    }

    @Test func targetNeedsDepthInsideTile() {
        let r = CGRect(x: 0, y: 0, width: 400, height: 300)
        #expect(isDeepInside(CGPoint(x: 200, y: 150), r))
        #expect(!isDeepInside(CGPoint(x: 5, y: 150), r))
        #expect(!isDeepInside(CGPoint(x: 200, y: 296), r))
        // tiny tile: margin shrinks, centre still counts
        #expect(isDeepInside(CGPoint(x: 20, y: 20), CGRect(x: 0, y: 0, width: 40, height: 40)))
    }

    @Test func relayoutOnlyOnTargetChange() {
        #expect(dragTargetChanged(previous: nil, new: 1))
        #expect(!dragTargetChanged(previous: 1, new: 1))
        #expect(dragTargetChanged(previous: 1, new: 2))
        #expect(!dragTargetChanged(previous: 1, new: nil))
    }

    @Test func previewFrameFlipsYAndInsets() {
        let f = dropPreviewFrame(of: CGRect(x: 100, y: 50, width: 400, height: 300), primaryScreenHeight: 1000)
        #expect(f == CGRect(x: 104, y: 654, width: 392, height: 292))
    }
}

@Suite struct DropZoneTests {
    let rect = CGRect(x: 100, y: 100, width: 400, height: 200) // centre (300, 200)

    @Test func edgesAndCenter() {
        #expect(dropZone(at: CGPoint(x: 300, y: 200), in: rect) == .center)
        #expect(dropZone(at: CGPoint(x: 330, y: 215), in: rect) == .center)
        #expect(dropZone(at: CGPoint(x: 120, y: 200), in: rect) == .left)
        #expect(dropZone(at: CGPoint(x: 480, y: 200), in: rect) == .right)
        #expect(dropZone(at: CGPoint(x: 300, y: 110), in: rect) == .top)
        #expect(dropZone(at: CGPoint(x: 300, y: 290), in: rect) == .bottom)
    }

    @Test func diagonalsAreNormalizedToTheTile() {
        // wide tile: 150px right of centre is only 0.75 of the half-width, 60px below is 0.6 of the half-height
        #expect(dropZone(at: CGPoint(x: 450, y: 260), in: rect) == .right)
        #expect(dropZone(at: CGPoint(x: 450, y: 290), in: rect) == .bottom) // ny 0.9 > nx 0.75
    }

    @Test func hysteresisKeepsPreviousZoneOnTheBoundary() {
        // exactly on the diagonal bottom-right: nx = ny = 0.8
        let p = CGPoint(x: 300 + 0.8 * 200, y: 200 + 0.8 * 100)
        #expect(dropZone(at: p, in: rect, previous: .right) == .right)
        #expect(dropZone(at: p, in: rect, previous: .bottom) == .bottom)
        // a clear step across wins
        let q = CGPoint(x: 300 + 0.5 * 200, y: 200 + 0.8 * 100)
        #expect(dropZone(at: q, in: rect, previous: .right) == .bottom)
        // leaving / entering the centre needs a margin too
        let edgeish = CGPoint(x: 300 + 0.35 * 200, y: 200)
        #expect(dropZone(at: edgeish, in: rect, previous: .center) == .center)
        #expect(dropZone(at: edgeish, in: rect, previous: .right) == .right)
        #expect(dropZone(at: edgeish, in: rect) == .right)
    }

    @Test func previewShowsTheTargetHalf() {
        #expect(dropZoneRect(of: rect, zone: .center) == rect)
        #expect(dropZoneRect(of: rect, zone: .left) == CGRect(x: 100, y: 100, width: 200, height: 200))
        #expect(dropZoneRect(of: rect, zone: .right) == CGRect(x: 300, y: 100, width: 200, height: 200))
        #expect(dropZoneRect(of: rect, zone: .top) == CGRect(x: 100, y: 100, width: 400, height: 100))
        #expect(dropZoneRect(of: rect, zone: .bottom) == CGRect(x: 100, y: 200, width: 400, height: 100))
    }

    @Test func zoneChangeRelaysOut() {
        let a = DropTarget(windowId: 1, zone: .top), b = DropTarget(windowId: 1, zone: .bottom)
        #expect(dragTargetChanged(previous: a, new: b))
        #expect(!dragTargetChanged(previous: a, new: a))
        #expect(dragTargetChanged(previous: nil, new: a))
    }

    @Test func placementDecision() {
        #expect(dropPlacement(zone: .center, parentOrientation: .h, parentChildCount: 2) == .swap)
        #expect(dropPlacement(zone: .right, parentOrientation: .h, parentChildCount: 2) == .sibling(after: true))
        #expect(dropPlacement(zone: .left, parentOrientation: .h, parentChildCount: 3) == .sibling(after: false))
        #expect(dropPlacement(zone: .bottom, parentOrientation: .v, parentChildCount: 2) == .sibling(after: true))
        #expect(dropPlacement(zone: .top, parentOrientation: .v, parentChildCount: 2) == .sibling(after: false))
        #expect(dropPlacement(zone: .bottom, parentOrientation: .h, parentChildCount: 2) == .wrap(.v, draggedFirst: false))
        #expect(dropPlacement(zone: .top, parentOrientation: .h, parentChildCount: 2) == .wrap(.v, draggedFirst: true))
        #expect(dropPlacement(zone: .left, parentOrientation: .v, parentChildCount: 2) == .wrap(.h, draggedFirst: true))
        #expect(dropPlacement(zone: .right, parentOrientation: .v, parentChildCount: 2) == .wrap(.h, draggedFirst: false))
        // target alone in its parent: just turn the parent around
        #expect(dropPlacement(zone: .bottom, parentOrientation: .h, parentChildCount: 1) == .reorient(.v, after: true))
        #expect(dropPlacement(zone: .left, parentOrientation: .h, parentChildCount: 1) == .reorient(.h, after: false))
    }
}

@MainActor @Suite(.serialized) struct DropTreeTests {
    /// root(h)[a, b, c] with plain container nodes standing in for windows
    private func tree() -> (root: TilingContainer, a: TilingContainer, b: TilingContainer, c: TilingContainer) {
        for w in Workspace.all { for child in w.children { child.unbindFromParent() } }
        let root = Workspace.get(byName: "dropTreeTests").rootTilingContainer
        root.changeOrientation(.h)
        let a = TilingContainer.newHTiles(parent: root, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        let b = TilingContainer.newHTiles(parent: root, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        let c = TilingContainer.newHTiles(parent: root, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        return (root, a, b, c)
    }

    @Test func belowWrapsTargetInVerticalContainer() {
        let (root, a, b, c) = tree()
        dropTilingNode(c, on: a, zone: .bottom)
        #expect(root.children.count == 2 && root.children[1] === b)
        let split = root.children[0] as? TilingContainer
        #expect(split?.orientation == .v)
        #expect(split?.children.count == 2 && split?.children[0] === a && split?.children[1] === c)
        #expect(a.getWeight(.v) == c.getWeight(.v))
    }

    @Test func topPutsDraggedFirst() {
        let (root, a, _, c) = tree()
        dropTilingNode(c, on: a, zone: .top)
        let split = root.children[0] as? TilingContainer
        #expect(split?.orientation == .v)
        #expect(split?.children[0] === c && split?.children[1] === a)
    }

    @Test func matchingOrientationInsertsSibling() {
        let (root, a, b, c) = tree()
        dropTilingNode(c, on: a, zone: .right)
        #expect(root.children.count == 3)
        #expect(root.children[0] === a && root.children[1] === c && root.children[2] === b)
        dropTilingNode(c, on: a, zone: .left)
        #expect(root.children[0] === c && root.children[1] === a && root.children[2] === b)
    }

    @Test func targetAloneInParentReorientsIt() {
        let (root, a, b, c) = tree()
        c.unbindFromParent()
        // root = [a, b]; taking b out leaves a alone: drop b below it
        dropTilingNode(b, on: a, zone: .bottom)
        #expect(root.orientation == .v)
        #expect(root.children.count == 2 && root.children[0] === a && root.children[1] === b)
        _ = c
    }

    @Test func leavesNoEmptyContainerBehind() {
        let (root, a, b, c) = tree()
        // b and c share an inner container; moving both out must not leave an empty one
        let inner = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        b.bind(to: inner, adaptiveWeight: 1, index: 0)
        c.bind(to: inner, adaptiveWeight: 1, index: 1)
        dropTilingNode(b, on: a, zone: .right)
        dropTilingNode(c, on: a, zone: .right)
        #expect(inner.children.isEmpty) // the caller's normalizeContainers() unbinds it
        Workspace.get(byName: "dropTreeTests").normalizeContainers()
        #expect(!root.children.contains { $0 === inner })
    }

    @Test func centerIsNotATreeOperation() {
        let (root, a, b, c) = tree()
        dropTilingNode(c, on: a, zone: .center)
        #expect(root.children[0] === a && root.children[1] === b && root.children[2] === c)
    }
}
