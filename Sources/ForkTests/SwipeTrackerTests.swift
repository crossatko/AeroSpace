import Testing
@testable import AppBundle

private func fingers(_ n: Int, x: Double, y: Double = 0.5, resting: Bool = false, ended: Bool = false) -> [TouchSample] {
    (0 ..< n).map { TouchSample(x: x + Double($0) * 0.02, y: y, isResting: resting, isEnded: ended) }
}

/// Feeds events and returns the actions emitted.
private func run(_ t: inout SwipeTracker, _ events: [(Double, [TouchSample])]) -> [SwipeAction] {
    events.compactMap { t.feed($0.1, at: $0.0) }
}

@Suite struct SwipeTrackerTests {
    @Test func cleanSwipeRightIsPrevWhenNatural() {
        var t = SwipeTracker()
        #expect(run(&t, [(0, fingers(3, x: 0.3)), (0.02, fingers(3, x: 0.4)), (0.04, fingers(3, x: 0.5))]) == [.prev])
    }

    @Test func cleanSwipeLeftIsNextWhenNatural() {
        var t = SwipeTracker()
        #expect(run(&t, [(0, fingers(3, x: 0.6)), (0.02, fingers(3, x: 0.5)), (0.04, fingers(3, x: 0.4))]) == [.next])
    }

    @Test func nonNaturalInvertsDirection() {
        var t = SwipeTracker(natural: false)
        #expect(run(&t, [(0, fingers(3, x: 0.3)), (0.02, fingers(3, x: 0.5))]) == [.next])
    }

    @Test func emptyEventsMidSwipeDoNotResetAndSwitchOnce() {
        var t = SwipeTracker()
        let events: [(Double, [TouchSample])] = [
            (0.00, fingers(3, x: 0.3)), (0.02, []), (0.04, fingers(3, x: 0.35)), (0.06, []),
            (0.08, fingers(3, x: 0.42)), (0.10, []), (0.12, fingers(3, x: 0.50)), (0.14, []),
            (0.16, fingers(3, x: 0.60)), (0.18, []),
        ]
        #expect(run(&t, events) == [.prev])
    }

    @Test func restingTouchesAreIgnored() {
        var t = SwipeTracker()
        // a resting thumb makes 4 touches; the 3 active ones still count
        func ev(_ x: Double) -> [TouchSample] { fingers(3, x: x) + [TouchSample(x: 0.9, y: 0.1, isResting: true)] }
        #expect(run(&t, [(0, ev(0.3)), (0.02, ev(0.4)), (0.04, ev(0.5))]) == [.prev])
        // only resting touches never do anything
        var u = SwipeTracker()
        #expect(run(&u, [(0, fingers(3, x: 0.3, resting: true)), (0.02, fingers(3, x: 0.6, resting: true))]).isEmpty)
    }

    @Test func wrongFingerCountIgnored() {
        for n in [2, 4] {
            var t = SwipeTracker()
            #expect(run(&t, [(0, fingers(n, x: 0.2)), (0.02, fingers(n, x: 0.5)), (0.04, fingers(n, x: 0.8))]).isEmpty)
        }
    }

    @Test func fourFingerConfig() {
        var t = SwipeTracker(fingers: 4)
        #expect(run(&t, [(0, fingers(3, x: 0.2)), (0.02, fingers(3, x: 0.8))]).isEmpty)
        #expect(run(&t, [(1, fingers(4, x: 0.3)), (1.02, fingers(4, x: 0.5))]) == [.prev])
    }

    @Test func belowThresholdDoesNotSwitch() {
        var t = SwipeTracker(threshold: 0.2)
        #expect(run(&t, [(0, fingers(3, x: 0.3)), (0.02, fingers(3, x: 0.4)), (0.04, fingers(3, x: 0.45))]).isEmpty)
    }

    @Test func mostlyVerticalMovementIgnored() {
        var t = SwipeTracker()
        #expect(run(&t, [(0, fingers(3, x: 0.3, y: 0.2)), (0.02, fingers(3, x: 0.5, y: 0.9))]).isEmpty)
    }

    @Test func oneSwitchPerLongSwipe() {
        var t = SwipeTracker()
        let events = (0 ... 30).map { (Double($0) * 0.01, fingers(3, x: 0.1 + Double($0) * 0.02)) }
        #expect(run(&t, events) == [.prev])
    }

    @Test func liftThenNewSwipeSwitchesAgain() {
        var t = SwipeTracker()
        let first: [(Double, [TouchSample])] = [(0, fingers(3, x: 0.3)), (0.02, fingers(3, x: 0.5))]
        #expect(run(&t, first) == [.prev])
        // no events for longer than the lift gap, then a new swipe the other way
        #expect(run(&t, [(1.0, fingers(3, x: 0.6)), (1.02, fingers(3, x: 0.4))]) == [.next])
    }

    @Test func explicitEndedPhaseCountsAsLift() {
        var t = SwipeTracker()
        #expect(run(&t, [(0, fingers(3, x: 0.3)), (0.02, fingers(3, x: 0.5))]) == [.prev])
        // all fingers ended, new swipe right away (within the lift gap)
        #expect(run(&t, [(0.04, fingers(3, x: 0.5, ended: true)), (0.05, fingers(3, x: 0.3)), (0.06, fingers(3, x: 0.5))]) == [.prev])
    }

    @Test func emptyEventsAloneNeverResetUntilGapPasses() {
        var t = SwipeTracker()
        // fired, then empties within the gap, then fingers continue: still one switch
        #expect(run(&t, [(0, fingers(3, x: 0.3)), (0.02, fingers(3, x: 0.5)), (0.04, []), (0.06, fingers(3, x: 0.7))]) == [.prev])
    }
}

@Suite struct MagicMouseTouchTests {
    @Test func deviceClassification() {
        #expect(isMagicMouseDevice(isBuiltIn: false, familyId: 112))
        #expect(!isMagicMouseDevice(isBuiltIn: true, familyId: 112))
        #expect(!isMagicMouseDevice(isBuiltIn: true, familyId: 114))
        #expect(!isMagicMouseDevice(isBuiltIn: false, familyId: 128))
    }

    @Test func contactStates() {
        #expect(!magicMouseSample(x: 0.5, y: 0.5, state: 4).isResting)
        #expect(magicMouseSample(x: 0.5, y: 0.5, state: 2).isResting)
        #expect(magicMouseSample(x: 0.5, y: 0.5, state: 6).isEnded)
        #expect(!magicMouseSample(x: 0.5, y: 0.5, state: 4).isEnded)
    }

    @Test func twoFingerMouseSwipe() {
        var t = SwipeTracker(fingers: 2, threshold: 0.25, natural: true)
        let f = { (x: Double) in [magicMouseSample(x: x, y: 0.5, state: 4), magicMouseSample(x: x + 0.02, y: 0.5, state: 4)] }
        #expect([0.2, 0.3, 0.5].enumerated().compactMap { t.feed(f($1), at: Double($0) * 0.02) } == [.prev])
    }
}
