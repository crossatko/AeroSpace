import AppKit

// Pure helpers of the live mouse drag (testable, no AX / tree access).

/// Rate limiter for the live drag updates. `fire` says whether an update may run now;
/// `remaining` tells how long a trailing update has to wait so the last cursor position
/// is never dropped.
struct DragThrottle {
    var interval: TimeInterval = 1.0 / 60
    private(set) var last: TimeInterval = -.infinity

    mutating func fire(at now: TimeInterval) -> Bool {
        if now - last < interval { return false }
        last = now
        return true
    }

    func remaining(at now: TimeInterval) -> TimeInterval {
        max(0, interval - (now - last))
    }
}

/// A tile only takes over the drag when the cursor is clearly inside it, not on its border:
/// without the margin the layout flips back and forth while the cursor sits on the edge
/// between two tiles (the swap moves the tiles under it).
func dragTargetMargin(for rect: CGRect) -> CGFloat {
    min(24, rect.width / 4, rect.height / 4)
}

func isDeepInside(_ point: CGPoint, _ rect: CGRect) -> Bool {
    rect.insetBy(dx: dragTargetMargin(for: rect), dy: dragTargetMargin(for: rect)).contains(point)
}

/// Whether the live layout has to be redone: only when the slot the dragged window would
/// take changed (and exists), never per pixel.
func dragTargetChanged(previous: UInt32?, new: UInt32?) -> Bool {
    new != nil && new != previous
}

/// Frame of the drop preview panel (bottom-left origin) for a tile rect (top-left origin)
func dropPreviewFrame(of rect: CGRect, primaryScreenHeight: CGFloat, inset: CGFloat = 4) -> CGRect {
    CGRect(x: rect.minX, y: primaryScreenHeight - rect.minY - rect.height, width: rect.width, height: rect.height)
        .insetBy(dx: inset, dy: inset)
}

extension Rect {
    func toCGRect() -> CGRect { CGRect(x: topLeftX, y: topLeftY, width: width, height: height) }
}
