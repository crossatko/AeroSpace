import AppKit
import Combine
import Common

// `menu-bar-clickable`: a second NSStatusItem (next to the stock MenuBarExtra) that draws the
// workspaces as pills. Left click focuses a workspace, right click / Option-click opens a menu,
// scroll (menu-bar-scroll-switch) goes to the next/previous workspace.
// Data comes from TrayMenuModel, layout and hit-testing from workspaceBarLayout.swift.

@MainActor private var workspaceBar: ClickableWorkspaceBar? = nil

@MainActor func syncClickableWorkspaceBar(_ config: Config) {
    TrayMenuModel.shared.menuBarClickable = config.menuBarClickable
    if config.menuBarClickable {
        if workspaceBar == nil { workspaceBar = ClickableWorkspaceBar() }
        workspaceBar?.scrollSwitch = config.menuBarScrollSwitch
        workspaceBar?.configuredMaxWidth = CGFloat(config.menuBarMaxWidth)
        workspaceBar?.refresh()
    } else {
        workspaceBar?.remove()
        workspaceBar = nil
    }
}

@MainActor private final class ClickableWorkspaceBar {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 0)
    private let barView = WorkspaceBarView()
    private var subscriptions: Set<AnyCancellable> = []
    var scrollSwitch = false { didSet { barView.scrollSwitch = scrollSwitch } }
    var configuredMaxWidth: CGFloat = 0

    init() {
        statusItem.button?.addSubview(barView)
        // Clicks must go through the button's own action: the subview never gets mouseUp, because it does not
        // override mouseDown, so the event goes up to NSStatusBarButton, whose tracking loop swallows mouseUp.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(barClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let model = TrayMenuModel.shared
        // @Published emits before the property changes, so the sinks use the emitted values
        model.$workspaces.sink { [weak self] ws in self?.refresh(workspaces: ws) }.store(in: &subscriptions)
        model.$isEnabled.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &subscriptions)
        model.$axPermissionStatus.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &subscriptions)
    }

    @objc private func barClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        let x = barLocalX(pointInButtonX: sender.convert(event.locationInWindow, from: nil).x, barOriginX: barView.frame.minX)
        let isRight = event.type == .rightMouseUp || event.modifierFlags.contains(.option)
        if isRight { barView.showMenu(atX: x, in: sender); return }
        if let name = barView.layout.hitTest(x: x) { focusWorkspaceFromBar(name) }
    }

    func remove() {
        subscriptions.removeAll()
        barView.removeFromSuperview()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func refresh() { refresh(workspaces: TrayMenuModel.shared.workspaces) }

    private func refresh(workspaces: [WorkspaceViewModel]) {
        let model = TrayMenuModel.shared
        let active = model.isEnabled && model.axPermissionStatus == .granted
        statusItem.isVisible = active
        guard active else { return }
        barView.metrics.maxWidth = autoMaxWidth()
        barView.workspaces = workspaces
        statusItem.length = barView.layout.totalWidth
        barView.frame = NSRect(x: 0, y: 0, width: barView.layout.totalWidth, height: NSStatusBar.system.thickness)
        barView.needsDisplay = true
    }

    /// 0 in the config = auto: 40% of the main screen width, minus the notch if there is one
    private func autoMaxWidth() -> CGFloat {
        if configuredMaxWidth > 0 { return configuredMaxWidth }
        guard let screen = NSScreen.screens.min(by: { $0.frame.width < $1.frame.width }) else { return 0 }
        var width = screen.frame.width * 0.4
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea { // notch
            width = min(width, max(left.width, right.width) - 200)
        }
        return max(width, 120)
    }
}

@MainActor private final class WorkspaceBarView: NSView {
    var metrics = WorkspaceBarMetrics()
    var scrollSwitch = false
    var workspaces: [WorkspaceViewModel] = [] { didSet { relayout() } }
    private(set) var layout = layoutWorkspaceBar([])
    private var scrollTracker = ScrollSwitchTracker()
    private let font = NSFont.menuBarFont(ofSize: 0)

    private func relayout() {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        layout = layoutWorkspaceBar(workspaces.map { ws in
            WorkspaceBarItem(
                name: ws.name,
                textWidth: ceil((ws.name as NSString).size(withAttributes: attrs).width),
                shortTextWidth: ceil((String(ws.name.prefix(1)) as NSString).size(withAttributes: attrs).width),
                isFocused: ws.isFocused, isVisible: ws.isVisible, isEmpty: ws.isEffectivelyEmpty,
                hasFullscreenWindows: ws.hasFullscreenWindows, monitorIndex: ws.monitorIndex,
            )
        }, metrics)
    }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        let pillHeight = min(h - 6, 18)
        let y = (h - pillHeight) / 2
        let color = NSColor.labelColor
        for pill in layout.pills {
            let item = pill.item
            let rect = NSRect(x: pill.x, y: y, width: pill.width, height: pillHeight)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            let text = pill.isCompact ? String(item.name.prefix(1)) : item.name
            let textSize = (text as NSString).size(withAttributes: [.font: font])
            let textOrigin = NSPoint(x: rect.minX + (rect.width - textSize.width) / 2, y: rect.minY + (rect.height - textSize.height) / 2)
            if item.isFocused {
                color.setFill()
                path.fill()
                // Knock the text out of the filled pill, like the stock label does
                NSGraphicsContext.current?.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                (text as NSString).draw(at: textOrigin, withAttributes: [.font: font, .foregroundColor: NSColor.black])
                NSGraphicsContext.current?.restoreGraphicsState()
            } else {
                let dim = item.isVisible ? 1 : 0.6
                color.withAlphaComponent(dim).setStroke()
                if item.isVisible || item.hasFullscreenWindows {
                    path.lineWidth = 1.5
                    if item.hasFullscreenWindows {
                        let dash: [CGFloat] = [4, 2]
                        unsafe path.setLineDash(dash, count: 2, phase: 0)
                    }
                    path.stroke()
                }
                (text as NSString).draw(at: textOrigin, withAttributes: [.font: font, .foregroundColor: color.withAlphaComponent(dim)])
            }
        }
        for x in layout.separators {
            color.withAlphaComponent(0.5).setFill()
            NSRect(x: x - 0.5, y: y + 2, width: 1, height: pillHeight - 4).fill()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard scrollSwitch else { return super.scrollWheel(with: event) }
        // Vertical wheel, or the dominant axis of a trackpad scroll
        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        if let dir = scrollTracker.feed(delta: delta, at: event.timestamp, isPrecise: event.hasPreciseScrollingDeltas, isGestureBegin: event.phase.contains(.began)) {
            switchWorkspaceFromBar(dir)
        }
    }

    func showMenu(atX x: CGFloat, in button: NSView) {
        let menu = NSMenu()
        let target = BarMenuTarget.shared
        for ws in TrayMenuModel.shared.workspaces {
            let item = NSMenuItem(title: ws.name + ws.suffix, action: #selector(BarMenuTarget.focus(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = ws.name
            item.state = ws.isFocused ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let reload = NSMenuItem(title: "Reload config", action: #selector(BarMenuTarget.reload), keyEquivalent: "")
        reload.target = target
        menu.addItem(reload)
        let quit = NSMenuItem(title: "Quit \(aeroSpaceAppName)", action: #selector(BarMenuTarget.quit), keyEquivalent: "")
        quit.target = target
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: 0), in: button)
    }
}

@MainActor private final class BarMenuTarget: NSObject {
    static let shared = BarMenuTarget()
    @objc func focus(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { focusWorkspaceFromBar(name) }
    }
    @objc func reload() {
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        Task.startUnstructured {
            try await runLightSession(.menuBarButton, token) {
                _ = await reloadConfig_nonCancellable(args: ReloadConfigCmdArgs(rawArgs: []))
            }
        }
    }
    @objc func quit() {
        Task.startUnstructured {
            terminationHandler?.beforeTermination()
            terminateApp()
        }
    }
}

// Same call as the stock menu (MenuBar.swift)
@MainActor private func focusWorkspaceFromBar(_ name: String) {
    guard let token: RunSessionGuard = .isServerEnabled else { return }
    Task.startUnstructured {
        try await runLightSession(.menuBarButton, token) { _ = Workspace.get(byName: name).focusWorkspace() }
    }
}

/// Same semantics as the trackpad swipe: next/prev among the non-empty workspaces of the monitor
/// under the cursor (plus the current one), no wrap-around.
@MainActor private func switchWorkspaceFromBar(_ direction: ScrollDirection) {
    guard let token: RunSessionGuard = .isServerEnabled else { return }
    Task.startUnstructured {
        try await runLightSession(.menuBarButton, token) {
            let current = mouseLocation.monitorApproximation.activeWorkspace
            let origin = current.workspaceMonitor.rect.topLeftCorner
            let names = Workspace.all
                .filter { $0.workspaceMonitor.rect.topLeftCorner == origin }
                .filter { $0 == current || !$0.isEffectivelyEmpty }
                .sorted().map(\.name).joined(separator: " ")
            var ignoredErrors: [String] = []
            let target = getNextPrevWorkspace(
                current: current, isNext: direction == .next, wrapAround: false, stdin: names, target: current.toLiveFocus(),
            )
            if let ws = target.getOrNil(appendErrorTo: &ignoredErrors), ws != current { _ = ws.focusWorkspace() }
        }
    }
}
