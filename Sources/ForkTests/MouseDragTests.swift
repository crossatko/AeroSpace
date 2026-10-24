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
