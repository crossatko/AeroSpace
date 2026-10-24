import AppKit
import Common

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

/// Result of one cursor sample of a tile move. The tree is not touched while dragging: the
/// target and the preview come from the unchanged layout, the drop is applied at mouse up.
enum DropTargetUpdate: Equatable {
    /// over the window's own slot / no tile: nothing to drop on, the preview goes away
    case reset
    /// on a tile border (not deep inside): the previous target and preview stay
    case keep
    case set(DropTarget, previewRect: CGRect)
}

/// `hit` = the other tile under the cursor (id, rect of the unchanged layout), nil for the
/// dragged window's own slot or no tile.
func dropTargetUpdate(hit: (id: UInt32, rect: CGRect)?, point: CGPoint, previous: DropTarget?) -> DropTargetUpdate {
    guard let hit else { return .reset }
    guard isDeepInside(point, hit.rect) else { return .keep }
    let zone = dropZone(at: point, in: hit.rect, previous: previous?.windowId == hit.id ? previous?.zone : nil)
    return .set(DropTarget(windowId: hit.id, zone: zone), previewRect: dropZoneRect(of: hit.rect, zone: zone))
}

/// Where in a target tile the cursor is: the four edge regions (a diagonal partition, so the
/// zones keep their shape on wide and tall tiles alike) and the middle (swap).
enum DropZone: Equatable, Sendable {
    case left, right, top, bottom, center

    var orientation: Orientation? {
        switch self {
            case .left, .right: .h
            case .top, .bottom: .v
            case .center: nil
        }
    }
    /// The dragged window ends up second (right / below the target)
    var isAfter: Bool { self == .right || self == .bottom }
}

/// What a drop does: the cursor in a tile, and the zone it was in
struct DropTarget: Equatable {
    let windowId: UInt32
    let zone: DropZone
}

/// Middle region = swap: the cursor within this fraction of the half-size on both axes
let dropCenterThreshold: CGFloat = 0.3
/// A zone only gives way to another one when the other scores this much higher (anti-flicker)
let dropZoneHysteresis: CGFloat = 0.12

/// Zone of `point` in `rect`. Each edge scores the cursor offset towards it, normalized by the
/// half-size of the tile (-1...1), so the dominant axis wins: the boundaries between the edge
/// zones are the tile's diagonals, whatever its aspect ratio. The middle scores a constant
/// (`dropCenterThreshold`). The `previous` zone is kept unless a competitor beats its score by
/// `dropZoneHysteresis`, so the zone doesn't flip on the boundaries.
func dropZone(at point: CGPoint, in rect: CGRect, previous: DropZone? = nil) -> DropZone {
    guard rect.width > 0, rect.height > 0 else { return .center }
    let nx = (point.x - rect.midX) / (rect.width / 2)
    let ny = (point.y - rect.midY) / (rect.height / 2) // y grows downwards
    func score(_ zone: DropZone) -> CGFloat {
        switch zone {
            case .left: -nx
            case .right: nx
            case .top: -ny
            case .bottom: ny
            case .center: dropCenterThreshold
        }
    }
    let all: [DropZone] = [.center, .left, .right, .top, .bottom]
    let best = all.max { score($0) < score($1) } ?? .center
    if let previous, previous != best, score(best) < score(previous) + dropZoneHysteresis { return previous }
    return best
}

/// The part of the tile the dragged window lands in (the whole tile for the swap)
func dropZoneRect(of rect: CGRect, zone: DropZone) -> CGRect {
    switch zone {
        case .center: rect
        case .left: CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .right: CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .top: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .bottom: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
    }
}

/// How the tree takes the dragged window next to the target
enum DropPlacement: Equatable {
    case swap
    /// parent already has the orientation: dragged window becomes a neighbour of the target
    case sibling(after: Bool)
    /// the target is alone in its parent: turn the parent around, then neighbour
    case reorient(Orientation, after: Bool)
    /// wrap the target in a new container with this orientation; dragged window first or second
    case wrap(Orientation, draggedFirst: Bool)
}

/// `parentOrientation` / `parentChildCount` are those of the target's parent after the dragged
/// window was taken out of the tree.
func dropPlacement(zone: DropZone, parentOrientation: Orientation, parentChildCount: Int) -> DropPlacement {
    guard let wanted = zone.orientation else { return .swap }
    if parentChildCount <= 1 { return .reorient(wanted, after: zone.isAfter) }
    if parentOrientation == wanted { return .sibling(after: zone.isAfter) }
    return .wrap(wanted, draggedFirst: !zone.isAfter)
}

/// Frame of the drop preview panel (bottom-left origin) for a tile rect (top-left origin)
func dropPreviewFrame(of rect: CGRect, primaryScreenHeight: CGFloat, inset: CGFloat = 4) -> CGRect {
    CGRect(x: rect.minX, y: primaryScreenHeight - rect.minY - rect.height, width: rect.width, height: rect.height)
        .insetBy(dx: inset, dy: inset)
}

extension Rect {
    func toCGRect() -> CGRect { CGRect(x: topLeftX, y: topLeftY, width: width, height: height) }
}
