import CoreGraphics
import Foundation

// Pure logic of the clickable menu bar workspaces (no AppKit): which workspaces are shown,
// where each pill goes, which workspace a click hits, and how scrolling maps to next/prev.

struct WorkspaceBarItem: Equatable {
    let name: String
    /// Width of the text drawn in the pill
    let textWidth: CGFloat
    /// Width of the compact form (first character), used when the width cap is exceeded
    let shortTextWidth: CGFloat
    let isFocused: Bool
    let isVisible: Bool
    let isEmpty: Bool
    let hasFullscreenWindows: Bool
    /// Index of the monitor (left to right) the workspace belongs to
    let monitorIndex: Int
    /// Text shown instead of the name (menu-bar-workspace-labels = 'binding'); the name stays the identity
    let label: String?

    var display: String { label ?? name }

    init(
        name: String, textWidth: CGFloat, shortTextWidth: CGFloat? = nil, isFocused: Bool = false, isVisible: Bool = false,
        isEmpty: Bool = false, hasFullscreenWindows: Bool = false, monitorIndex: Int = 0,
        label: String? = nil,
    ) {
        self.name = name
        self.textWidth = textWidth
        self.shortTextWidth = shortTextWidth ?? textWidth
        self.isFocused = isFocused
        self.isVisible = isVisible
        self.isEmpty = isEmpty
        self.hasFullscreenWindows = hasFullscreenWindows
        self.monitorIndex = monitorIndex
        self.label = label
    }

    /// Only occupied, visible (shown on some monitor) and focused workspaces are shown
    var isShown: Bool { !isEmpty || isVisible || isFocused }
}

struct WorkspaceBarMetrics: Equatable {
    var pillPadding: CGFloat = 8
    var spacing: CGFloat = 4
    var groupGap: CGFloat = 12
    /// 0 = unlimited
    var maxWidth: CGFloat = 0
}

struct WorkspaceBarPill: Equatable {
    let item: WorkspaceBarItem
    let x: CGFloat
    let width: CGFloat
    /// The compact form is drawn instead of the full name
    let isCompact: Bool
    var maxX: CGFloat { x + width }
}

struct WorkspaceBarLayout: Equatable {
    let pills: [WorkspaceBarPill]
    /// x of the center of each gap between monitor groups (not clickable)
    let separators: [CGFloat]
    let totalWidth: CGFloat
    /// Workspaces dropped because of the width cap
    let hiddenCount: Int
    let spacing: CGFloat

    /// The workspace under x. A gap between two pills of one monitor belongs to the nearer pill,
    /// a gap between monitor groups and everything outside the widget is nil.
    func hitTest(x: CGFloat) -> String? {
        guard x >= 0, x < totalWidth else { return nil }
        let slop = spacing / 2
        return pills.first { x >= $0.x - slop && x < $0.maxX + slop }?.item.name
    }
}

func layoutWorkspaceBar(_ allItems: [WorkspaceBarItem], _ m: WorkspaceBarMetrics = WorkspaceBarMetrics()) -> WorkspaceBarLayout {
    // Group by monitor, keeping the given order inside a group
    var items = allItems.filter(\.isShown).enumerated()
        .sorted { ($0.element.monitorIndex, $0.offset) < ($1.element.monitorIndex, $1.offset) }
        .map(\.element)
    let totalShown = items.count
    // Overflow, stage 1: compact the pills of workspaces that are not visible, stage 2: compact all but the focused
    // one, stage 3: drop non-visible workspaces from the end. Visible and focused ones are always kept.
    func build(_ compact: (WorkspaceBarItem) -> Bool) -> WorkspaceBarLayout {
        var pills: [WorkspaceBarPill] = []
        var separators: [CGFloat] = []
        var x: CGFloat = 0
        for (i, item) in items.enumerated() {
            if let prev = items.getOrNil(i - 1) {
                if prev.monitorIndex != item.monitorIndex {
                    separators.append(x + m.groupGap / 2)
                    x += m.groupGap
                } else {
                    x += m.spacing
                }
            }
            let isCompact = compact(item)
            let w = (isCompact ? item.shortTextWidth : item.textWidth) + 2 * m.pillPadding
            pills.append(WorkspaceBarPill(item: item, x: x, width: w, isCompact: isCompact))
            x += w
        }
        return WorkspaceBarLayout(pills: pills, separators: separators, totalWidth: x, hiddenCount: totalShown - items.count, spacing: m.spacing)
    }
    let fits = { (l: WorkspaceBarLayout) in m.maxWidth <= 0 || l.totalWidth <= m.maxWidth }
    var layout = build { _ in false }
    if fits(layout) { return layout }
    layout = build { !$0.isVisible && !$0.isFocused }
    if fits(layout) { return layout }
    layout = build { !$0.isFocused }
    while !fits(layout), let drop = items.lastIndex(where: { !$0.isVisible && !$0.isFocused }) {
        items.remove(at: drop)
        layout = build { !$0.isFocused }
    }
    return layout
}

private extension Array {
    func getOrNil(_ i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

enum ScrollDirection: Equatable { case next, prev }

/// Turns scroll events into at most one workspace switch per flick: trackpad momentum events keep
/// arriving after the fingers lift, so after a switch everything is ignored until a new gesture
/// begins or the events pause for `quietGap`. A wheel mouse switches once per notch, rate limited.
struct ScrollSwitchTracker {
    var threshold: Double = 6
    var quietGap: Double = 0.25
    var wheelInterval: Double = 0.08
    private var accumulated: Double = 0
    private var lastEvent: Double = -.infinity
    private var lastSwitch: Double = -.infinity
    private var locked = false

    /// delta > 0 (scroll up) = previous workspace, delta < 0 = next
    mutating func feed(delta: Double, at time: Double, isPrecise: Bool, isGestureBegin: Bool = false) -> ScrollDirection? {
        defer { lastEvent = time }
        guard delta != 0 else { return nil }
        if !isPrecise {
            let direction: ScrollDirection = delta > 0 ? .prev : .next
            guard time - lastSwitch >= wheelInterval else { return nil }
            lastSwitch = time
            return direction
        }
        if isGestureBegin || time - lastEvent > quietGap {
            accumulated = 0
            locked = false
        }
        if locked { return nil }
        accumulated += delta
        guard abs(accumulated) >= threshold else { return nil }
        locked = true
        let direction: ScrollDirection = accumulated > 0 ? .prev : .next
        accumulated = 0
        lastSwitch = time
        return direction
    }
}

/// A click x in the status button's coordinate space -> x in the bar view's space (the view sits at barOriginX in the button).
func barLocalX(pointInButtonX x: CGFloat, barOriginX: CGFloat) -> CGFloat { x - barOriginX }

// MARK: pill labels from key bindings (menu-bar-workspace-labels = 'binding')

/// A main-mode binding whose command is exactly `workspace <name>`: `notation` is the key notation as written in the config
/// ('ctrl-alt-shift-a', 'a'), `workspace` is the target name
struct WorkspaceBindingCandidate: Equatable {
    let notation: String
    let workspace: String
}

/// Workspace name -> the key that switches to it. If several bindings target a workspace, the one with the fewest modifiers
/// wins, then the alphabetically first notation. Workspaces without a binding are absent (the caller falls back to the name).
func workspaceLabelsFromBindings(_ candidates: [WorkspaceBindingCandidate]) -> [String: String] {
    func parts(_ c: WorkspaceBindingCandidate) -> [Substring] { c.notation.split(separator: "-", omittingEmptySubsequences: false) }
    var best: [String: WorkspaceBindingCandidate] = [:]
    for c in candidates where !parts(c).last.orDie().isEmpty {
        guard let cur = best[c.workspace] else { best[c.workspace] = c; continue }
        if (parts(c).count, c.notation) < (parts(cur).count, cur.notation) { best[c.workspace] = c }
    }
    return best.mapValues { String(parts($0).last.orDie()) }
}
