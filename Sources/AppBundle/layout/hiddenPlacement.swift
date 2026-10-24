import AppKit
import Common

/// How windows of inactive workspaces are parked
enum HiddenWindowPlacement: String, CaseIterable {
    /// Upstream behaviour: every hidden window goes to the same screen corner
    case corner
    /// Hidden windows go beyond the left edge (lower workspaces) or the right edge (higher workspaces), see `missionControlMirrorsParkedPositions`
    /// of the monitor, so Mission Control arranges workspaces spatially
    case directional
}

/// With 'Group windows by application' ON, Mission Control follows the parked sides directly (lower workspaces left).
/// With grouping OFF it appeared mirrored and became random with 3+ workspace groups (both observed on macOS 26.6).
/// Set to true to mirror for the grouping-off case. The vertical band order (nearest workspace on top) is unverified.
let missionControlMirrorsParkedPositions = false

enum HiddenEdge: Equatable {
    case left, right, bottom
}

/// Where a hidden workspace is parked: the edge, and a band along it (0 = nearest to the visible workspace)
struct HiddenSlot: Equatable {
    let edge: HiddenEdge
    let isLowerSide: Bool
    let band: Int
    let bandCount: Int
}

struct HiddenMonitorGeometry {
    let visibleRect: Rect
    var leftBlocked: Bool = false
    var rightBlocked: Bool = false
    var bottomBlocked: Bool = false

    /// An edge is blocked when parking windows beyond it would make them show up on a neighbouring monitor
    init(monitorRect: Rect, visibleRect: Rect, others: [Rect]) {
        self.visibleRect = visibleRect
        let fractions: [CGFloat] = [0.1, 0.3, 0.5, 0.7, 0.9]
        func hit(_ p: CGPoint) -> Bool { others.contains { $0.contains(p) } }
        leftBlocked = fractions.contains {
            hit(CGPoint(x: monitorRect.minX - 2, y: monitorRect.minY + monitorRect.height * $0))
        }
        rightBlocked = fractions.contains {
            hit(CGPoint(x: monitorRect.maxX + 2, y: monitorRect.minY + monitorRect.height * $0))
        }
        bottomBlocked = fractions.contains {
            hit(CGPoint(x: monitorRect.minX + monitorRect.width * $0, y: monitorRect.maxY + 2))
        }
    }
}

/// - Parameters:
///   - workspaces: names of the visible workspace and of the hidden ones that have windows, in AeroSpace's workspace order
///   - visible: name of the workspace visible on the monitor
/// - Returns: slot per hidden workspace. A workspace is absent when no edge is usable (caller falls back to the corner)
func hiddenSlots(workspaces: [String], visible: String, geometry: HiddenMonitorGeometry) -> [String: HiddenSlot] {
    guard let visibleIndex = workspaces.firstIndex(of: visible) else { return [:] }
    let lower = Array(workspaces[..<visibleIndex].reversed()) // nearest to the visible workspace first
    let higher = Array(workspaces[(visibleIndex + 1)...])
    var result: [String: HiddenSlot] = [:]
    for (names, isLower) in [(lower, true), (higher, false)] {
        let useRight = isLower == missionControlMirrorsParkedPositions
        let preferredBlocked = useRight ? geometry.rightBlocked : geometry.leftBlocked
        let edge: HiddenEdge
        if !preferredBlocked {
            edge = useRight ? .right : .left
        } else if !geometry.bottomBlocked {
            edge = .bottom
        } else {
            continue
        }
        for (band, name) in names.enumerated() {
            result[name] = HiddenSlot(edge: edge, isLowerSide: isLower, band: band, bandCount: names.count)
        }
    }
    return result
}

/// - Parameters:
///   - relative: where the window's top left corner was inside the monitor before hiding, 0...1 on both axes.
///     Keeps the relative layout of the windows of a workspace
///   - windowWidth: only used for the left edge
func hiddenTarget(slot: HiddenSlot, geometry: HiddenMonitorGeometry, windowWidth: CGFloat, relative: CGPoint, isZoom: Bool) -> CGPoint {
    // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/AeroSpace/issues/527
    let sliver: CGFloat = isZoom ? 0 : 1
    let r = geometry.visibleRect
    let n = CGFloat(max(1, slot.bandCount))
    func unit(_ v: CGFloat) -> CGFloat { min(max(v, 0), 0.999) }
    switch slot.edge {
        case .left, .right:
            // Bands are stacked vertically, the nearest workspace on top
            let y = r.minY + r.height * (CGFloat(slot.band) + unit(relative.y)) / n
            let x = slot.edge == .left ? r.minX + sliver - windowWidth : r.maxX - sliver
            return CGPoint(x: x, y: min(y, r.maxY - 1))
        case .bottom:
            // Lower workspaces in the left half, higher in the right half (swapped when mirroring); the nearest one is next to the middle
            let half = r.width / 2
            let inRightHalf = slot.isLowerSide == missionControlMirrorsParkedPositions
            let index = inRightHalf ? slot.band : slot.bandCount - 1 - slot.band
            let start = inRightHalf ? r.minX + half : r.minX
            let x = start + half * (CGFloat(index) + unit(relative.x)) / n
            return CGPoint(x: min(x, r.maxX - 1), y: r.maxY - sliver)
    }
}
