import Foundation

// Pure helpers for the Magic Mouse workspace swipe (no private API, unit tested in ForkTests).

/// MultitouchSupport family ids of Magic Mouse generations. Built-in and external trackpads use others.
func isMagicMouseDevice(isBuiltIn: Bool, familyId: Int32) -> Bool {
    !isBuiltIn && (112 ... 113).contains(familyId)
}

/// MultitouchSupport contact states: 4 = touching. Hovering (1...3) and lifting (5...7) fingers are not
/// part of a swipe: a hovering or lingering contact is treated as resting, a breaking one as ended.
func magicMouseSample(x: Double, y: Double, state: Int32) -> TouchSample {
    TouchSample(x: x, y: y, isResting: state != 4 && state != 5, isEnded: state >= 5)
}
