import AppKit
import Common

@MainActor
private var moveWithMouseTask: Task<(), any Error>? = nil

func movedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let windowId = ax.containingWindowId()
    let notif = notif as String
    Task.startUnstructured { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        if isMouseDragInProgress { return } // mouse-modifier drag: its own live layout + one refresh at mouse up
        guard let windowId, let window = Window.get(byId: windowId), try await isManipulatedWithMouse(window) else {
            scheduleCancellableCompleteRefreshSession(.ax(notif))
            return
        }
        moveWithMouseTask?.cancel()
        moveWithMouseTask = Task.startUnstructured {
            try checkCancellation()
            try await runLightSession(.ax(notif), token) {
                try await moveWithMouse(window)
            }
        }
    }
}

@MainActor
func moveWithMouse(_ window: Window) async throws { // todo cover with tests
    resetClosedWindowsCache()
    switch window.windowParentCases {
        case .floatingWindowsContainer:
            try await moveFloatingWindow(window)
        case .macosFullscreenWindowsContainer, .macosMinimizedWindowsContainer, .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Unconventional windows can't be moved with mouse
        case .tilingContainer:
            moveTilingWindow(window)
        case .unbound: return
    }
}

@MainActor
private func moveFloatingWindow(_ window: Window) async throws {
    guard let targetWorkspace = try await window.getCenter(.cancellable)?.monitorApproximation.activeWorkspace else { return }
    guard let parent = window.parent else { return }
    if targetWorkspace != parent {
        window.bindAsFloatingWindow(to: targetWorkspace)
    }
}

@MainActor
func moveTilingWindow(_ window: Window) {
    currentlyManipulatedWithMouseWindowId = window.windowId
    window.lastAppliedLayoutPhysicalRect = nil
    let mouseLocation = mouseLocation
    let targetWorkspace = mouseLocation.monitorApproximation.activeWorkspace
    let swapTarget = mouseLocation
        .findWindowRecursively(in: targetWorkspace.rootTilingContainer, virtual: false, fullscreenCoversAll: false)?
        .takeIf { $0 != window }
    if targetWorkspace != window.nodeWorkspace { // Move window to a different monitor
        let index: Int = if let swapTarget, let parent = swapTarget.parent as? TilingContainer, let targetRect = swapTarget.lastAppliedLayoutPhysicalRect {
            mouseLocation.getProjection(parent.orientation) >= targetRect.center.getProjection(parent.orientation)
                ? swapTarget.ownIndex.orDie() + 1
                : swapTarget.ownIndex.orDie()
        } else {
            0
        }
        window.bind(
            to: swapTarget?.parent ?? targetWorkspace.rootTilingContainer,
            adaptiveWeight: WEIGHT_AUTO,
            index: index,
        )
    } else if let swapTarget {
        swapWindows(mruDominant: window, swapTarget)
    }
}

/// Drop zone move: the window goes next to `target` (above / below / left / right of it) by
/// splitting the target's slot, see `dropPlacement`. The window may come from another workspace.
@MainActor
func dropTilingWindow(_ window: Window, on target: Window, zone: DropZone) {
    currentlyManipulatedWithMouseWindowId = window.windowId
    window.lastAppliedLayoutPhysicalRect = nil
    dropTilingNode(window, on: target, zone: zone)
}

/// The tree operation of `dropTilingWindow`, on plain nodes (testable without AX windows).
/// The caller normalizes the workspaces afterwards (flatten what the move left behind).
@MainActor
func dropTilingNode(_ node: TreeNode, on target: TreeNode, zone: DropZone) {
    guard zone != .center, node !== target, !target.parentsWithSelf.contains(where: { $0 === node }),
          let parent = target.parent as? TilingContainer else { return }
    node.unbindFromParent() // first: the target's parent may be the node's old parent
    switch dropPlacement(zone: zone, parentOrientation: parent.orientation, parentChildCount: parent.children.count) {
        case .swap: return
        case .reorient(let orientation, let after):
            parent.changeOrientation(orientation)
            node.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: target.ownIndex.orDie() + (after ? 1 : 0))
        case .sibling(let after):
            node.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: target.ownIndex.orDie() + (after ? 1 : 0))
        case .wrap(let orientation, let draggedFirst):
            let data = target.unbindFromParent()
            let split = TilingContainer(parent: parent, adaptiveWeight: data.adaptiveWeight, orientation, .tiles, index: data.index)
            target.bind(to: split, adaptiveWeight: WEIGHT_AUTO, index: 0)
            node.bind(to: split, adaptiveWeight: WEIGHT_AUTO, index: draggedFirst ? 0 : INDEX_BIND_LAST)
    }
}

@MainActor
func swapWindows(mruDominant window1: Window, _ window2: Window) {
    if window1 == window2 { return }

    let binding2 = window2.unbindFromParent()
    let binding1 = window1.unbindFromParent()

    window2.bind(to: binding1.parent, adaptiveWeight: binding1.adaptiveWeight, index: binding1.index)
    window1.bind(to: binding2.parent, adaptiveWeight: binding2.adaptiveWeight, index: binding2.index)
}

extension CGPoint {
    @MainActor
    func findWindowRecursively(
        in tree: TilingContainer,
        virtual: Bool,
        fullscreenCoversAll: Bool,
    ) -> Window? {
        if fullscreenCoversAll {
            if let window = tree.mostRecentWindowRecursive, window.isFullscreen {
                return window
            }
        }
        return _findWindowRecursively(in: tree, virtual: virtual)
    }

    @MainActor
    private func _findWindowRecursively(in tree: TilingContainer, virtual: Bool) -> Window? {
        let point = self
        let target: TreeNode? = switch tree.layout {
            case .tiles:
                tree.children.first(where: {
                    (virtual ? $0.lastAppliedLayoutVirtualRect : $0.lastAppliedLayoutPhysicalRect)?.contains(point) == true
                })
            case .accordion:
                tree.mostRecentChild
        }
        guard let target else { return nil }
        return switch target.tilingTreeNodeCasesOrDie() {
            case .window(let window): window
            case .tilingContainer(let container): _findWindowRecursively(in: container, virtual: virtual)
        }
    }
}
