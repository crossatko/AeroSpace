import AppKit
import Combine
import Common

// `menu-bar-clickable`: a second NSStatusItem (next to the stock MenuBarExtra) that draws the
// workspaces as pills. Left click focuses a workspace, right click / Option-click opens a menu,
// scroll (menu-bar-scroll-switch) goes to the next/previous workspace.
// Data comes from TrayMenuModel, layout and hit-testing from workspaceBarLayout.swift.

@MainActor private var workspaceBar: ClickableWorkspaceBar? = nil
@MainActor private var menuBarDebugLog = false

@MainActor private func menuBarLog(_ message: @autoclosure () -> String) {
    if menuBarDebugLog { appendDebugLog(file: "menubar.log", message()) }
}

@MainActor func syncClickableWorkspaceBar(_ config: Config) {
    TrayMenuModel.shared.menuBarClickable = config.menuBarClickable
    TrayMenuModel.shared.menuBarHideStockItem = config.menuBarHideStockItem
    menuBarDebugLog = config.menuBarDebugLog
    if config.menuBarClickable {
        if workspaceBar == nil { workspaceBar = ClickableWorkspaceBar() }
        workspaceBar?.scrollSwitch = config.menuBarScrollSwitch
        workspaceBar?.configuredMaxWidth = CGFloat(config.menuBarMaxWidth)
        workspaceBar?.setLabels(config.menuBarWorkspaceLabels == .binding ? workspaceLabelsFromBindings(mainModeWorkspaceBindings(config)) : [:])
        workspaceBar?.refresh()
        TrayMenuModel.shared.pillsInstalled = workspaceBar?.isInstalled ?? false
    } else {
        workspaceBar?.remove()
        workspaceBar = nil
        TrayMenuModel.shared.pillsInstalled = false
    }
}

/// The main-mode bindings that are exactly `workspace <name>`
@MainActor private func mainModeWorkspaceBindings(_ config: Config) -> [WorkspaceBindingCandidate] {
    (config.modes[mainModeId]?.bindings.values ?? [:].values).compactMap { binding in
        guard case .cmd(let cmd) = binding.commands, let ws = cmd as? WorkspaceCommand,
              case .direct(let name) = ws.args.target.val else { return nil }
        return WorkspaceBindingCandidate(notation: binding.descriptionWithKeyNotation, workspace: name.raw)
    }
}

@MainActor private final class ClickableWorkspaceBar {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 0)
    private let barView = WorkspaceBarView()
    private var subscriptions: Set<AnyCancellable> = []
    var scrollSwitch = false { didSet { barView.scrollSwitch = scrollSwitch } }
    var configuredMaxWidth: CGFloat = 0
    func setLabels(_ labels: [String: String]) { barView.labels = labels }
    var isInstalled: Bool { statusItem.button != nil }
    private var monitors: [Any] = []
    private var lastClickTimestamp: TimeInterval = -1

    init() {
        // The pills are drawn into the button's image (see refresh): system-hosted status items do not take custom subviews
        statusItem.button?.imagePosition = .imageOnly
        // Clicks must go through the button's own action: the subview never gets mouseUp, because it does not
        // override mouseDown, so the event goes up to NSStatusBarButton, whose tracking loop swallows mouseUp.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(barClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        installEventMonitors()
        menuBarLog("INSTALL button=\(statusItem.button != nil) window=\(statusItem.button?.window != nil)")
        let model = TrayMenuModel.shared
        // @Published emits before the property changes, so the sinks use the emitted values
        model.$workspaces.sink { [weak self] ws in self?.refresh(workspaces: ws) }.store(in: &subscriptions)
        model.$isEnabled.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &subscriptions)
        model.$axPermissionStatus.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &subscriptions)
    }

    @objc private func barClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { menuBarLog("ACTION no currentEvent"); return }
        let x = barLocalX(pointInButtonX: sender.convert(event.locationInWindow, from: nil).x, barOriginX: barOrigin(in: sender))
        menuBarLog("ACTION type=\(event.type.rawValue)")
        handleClick(type: event.type, option: event.modifierFlags.contains(.option), timestamp: event.timestamp, x: x)
    }

    private func handleClick(type: NSEvent.EventType, option: Bool, timestamp: TimeInterval, x: CGFloat) {
        guard let button = statusItem.button else { return }
        if timestamp == lastClickTimestamp { return } // the action and the event monitors both see a click, handle it once
        lastClickTimestamp = timestamp
        let isRight = type == .rightMouseUp || option
        let hit = barView.layout.hitTest(x: x)
        menuBarLog("CLICK x=\(Int(x)) right=\(isRight) hit=\(hit ?? "none")")
        if isRight { barView.showMenu(atX: x, in: button); return }
        if let hit { focusWorkspaceFromBar(hit) }
    }

    /// The button's own action and the subview's scrollWheel are not reliable on every macOS version, so mouse events over
    /// the item are also caught by monitors (local: events our app gets; global: events that go to another process).
    private func installEventMonitors() {
        let mask: NSEvent.EventTypeMask = [.scrollWheel, .leftMouseUp, .rightMouseUp]
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, let window = statusItem.button?.window, event.window === window else { return event }
            handleMonitored(event, local: true)
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                let p = NSEvent.mouseLocation
                if let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }), p.y > screen.frame.maxY - 40 {
                    let w = self?.statusItem.button?.window?.frame
                    menuBarLog("ANY type=\(event.type.rawValue) at=\(Int(p.x)),\(Int(p.y)) itemWindow=\(w.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "nil")")
                }
                self?.handleMonitored(event, local: false)
            }
        }
        monitors = [local, global].compactMap { $0 }
    }

    private func handleMonitored(_ event: NSEvent, local: Bool) {
        guard let button = statusItem.button, let window = button.window else { return }
        let screenPoint = local ? window.convertPoint(toScreen: event.locationInWindow) : NSEvent.mouseLocation
        guard window.frame.contains(screenPoint) else { return }
        let x = barLocalX(pointInButtonX: button.convert(window.convertPoint(fromScreen: screenPoint), from: nil).x, barOriginX: barOrigin(in: button))
        menuBarLog("EVENT local=\(local) type=\(event.type.rawValue) x=\(Int(x)) window=\(Int(window.frame.minX)),\(Int(window.frame.minY)) \(Int(window.frame.width))x\(Int(window.frame.height))")
        let type = event.type, option = event.modifierFlags.contains(.option), ts = event.timestamp
        if type == .scrollWheel {
            if barView.scrollSwitch, let dir = barView.feedScroll(event) {
                menuBarLog("SCROLL \(dir)")
                switchWorkspaceFromBar(dir)
            }
        } else {
            DispatchQueue.main.async { [weak self] in self?.handleClick(type: type, option: option, timestamp: ts, x: x) }
        }
    }

    /// x of the image inside the button (the button centers it and adds padding)
    private func barOrigin(in button: NSView) -> CGFloat {
        max(0, (button.bounds.width - barView.layout.totalWidth) / 2)
    }

    func remove() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        subscriptions.removeAll()
        statusItem.button?.image = nil
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
        let size = NSSize(width: max(barView.layout.totalWidth, 1), height: NSStatusBar.system.thickness)
        let view = barView
        statusItem.button?.image = NSImage(size: size, flipped: false) { _ in
            MainActor.assumeIsolated { view.drawPills(height: size.height) }
            return true
        }
        let w = statusItem.button?.window?.frame
        menuBarLog("REFRESH length=\(Int(statusItem.length)) pills=\(barView.layout.pills.count) visible=\(statusItem.isVisible) button=\(statusItem.button != nil) window=\(w.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "nil") image=\(Int(barView.layout.totalWidth))x\(Int(NSStatusBar.system.thickness))")
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
    var labels: [String: String] = [:] { didSet { if labels != oldValue { relayout(); needsDisplay = true } } }
    private(set) var layout = layoutWorkspaceBar([])
    private var scrollTracker = ScrollSwitchTracker()
    private let font = NSFont.menuBarFont(ofSize: 0)

    private func relayout() {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        layout = layoutWorkspaceBar(workspaces.map { ws in
            let text = labels[ws.name] ?? ws.name
            return WorkspaceBarItem(
                name: ws.name,
                textWidth: ceil((text as NSString).size(withAttributes: attrs).width),
                shortTextWidth: ceil((String(text.prefix(1)) as NSString).size(withAttributes: attrs).width),
                isFocused: ws.isFocused, isVisible: ws.isVisible, isEmpty: ws.isEffectivelyEmpty,
                hasFullscreenWindows: ws.hasFullscreenWindows, monitorIndex: ws.monitorIndex, label: labels[ws.name],
            )
        }, metrics)
    }

    func drawPills(height h: CGFloat) {
        let pillHeight = min(h - 6, 18)
        let y = (h - pillHeight) / 2
        let color = NSColor.labelColor
        for pill in layout.pills {
            let item = pill.item
            let rect = NSRect(x: pill.x, y: y, width: pill.width, height: pillHeight)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            let text = pill.isCompact ? String(item.display.prefix(1)) : item.display
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

    /// Scroll events arrive through the bar's event monitors (see installEventMonitors)
    func feedScroll(_ event: NSEvent) -> ScrollDirection? {
        // Vertical wheel, or the dominant axis of a trackpad scroll
        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        return scrollTracker.feed(delta: delta, at: event.timestamp, isPrecise: event.hasPreciseScrollingDeltas, isGestureBegin: event.phase.contains(.began))
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
        let enabled = TrayMenuModel.shared.isEnabled
        for (title, action) in [(enabled ? "Disable" : "Enable", #selector(BarMenuTarget.toggleEnabled)),
                                ("Open config", #selector(BarMenuTarget.openConfig)),
                                ("Reload config", #selector(BarMenuTarget.reload))]
        {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }
        menu.addItem(.separator())
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
        reloadConfigFromMenu(token)
    }
    @objc func toggleEnabled() { toggleEnabledFromMenu() }
    @objc func openConfig() { openConfigInEditor() }
    @objc func quit() { quitFromMenu() }
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
