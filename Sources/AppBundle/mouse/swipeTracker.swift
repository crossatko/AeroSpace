import Foundation

// Pure state machine for the trackpad workspace swipe (no AppKit, unit tested in ForkTests).
// Design notes ported from SwipeAeroSpace (MediosZ, MIT: ignores empty gesture events and
// resting touches) and Skyland's gestures.swift (MIT: finger count + travel).

/// One finger of one gesture event, in normalized trackpad coordinates (0...1, y up).
struct TouchSample: Equatable, Sendable {
    var x: Double
    var y: Double
    /// NSTouch.isResting (a thumb or palm lying on the pad)
    var isResting = false
    /// NSTouch phase ended or cancelled: the finger is lifting
    var isEnded = false
}

enum SwipeAction: Equatable, Sendable {
    case next, prev
}

struct SwipeTracker: Sendable {
    var fingers = 3
    /// Horizontal travel of the average finger position, in normalized trackpad units (1 = pad width)
    var threshold = 0.15
    /// Natural direction: content follows the fingers (fingers right = previous workspace)
    var natural = true
    /// No matching touches for longer than this (seconds) means the fingers really lifted.
    /// macOS interleaves empty 0-touch events mid-swipe, so a lift is never judged by a single event.
    var liftGap = 0.12

    private var startX: Double? = nil
    private var startY: Double = 0
    private var fired = false
    private var lastMatch: Double? = nil
    private var rebase = false

    init(fingers: Int = 3, threshold: Double = 0.15, natural: Bool = true) {
        self.fingers = fingers
        self.threshold = threshold
        self.natural = natural
    }

    private mutating func reset() {
        startX = nil
        fired = false
        lastMatch = nil
        rebase = false
    }

    /// Feed one gesture event (all its touches) with its timestamp in seconds.
    mutating func feed(_ touches: [TouchSample], at time: Double) -> SwipeAction? {
        if let last = lastMatch, time - last > liftGap { reset() }
        let active = touches.filter { !$0.isResting && !$0.isEnded }
        if active.isEmpty {
            // Empty event: ignored. Non-empty with only ended touches: a real lift.
            if !touches.isEmpty { reset() }
            return nil
        }
        guard active.count == fingers else {
            if startX != nil { rebase = true } // other finger count mid-swipe: restart from the next match
            return nil
        }
        lastMatch = time
        let x = active.map(\.x).reduce(0, +) / Double(active.count)
        let y = active.map(\.y).reduce(0, +) / Double(active.count)
        guard let sx = startX, !rebase else {
            if !fired { startX = x; startY = y }
            rebase = false
            return nil
        }
        if fired { return nil }
        let dx = x - sx, dy = y - startY
        guard abs(dx) >= threshold, abs(dx) > abs(dy) else { return nil }
        fired = true
        return (dx > 0) == natural ? .prev : .next
    }
}
