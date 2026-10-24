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
