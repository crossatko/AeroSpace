import AppKit

@MainActor var currentlyManipulatedWithMouseWindowId: UInt32? = nil
var isLeftMouseButtonDown: Bool { NSEvent.pressedMouseButtons == 1 }

@MainActor
func isManipulatedWithMouse(_ window: Window) async throws -> Bool {
    try await (!window.isHiddenInCorner && // Don't allow to resize/move windows of hidden workspaces
        isLeftMouseButtonDown &&
        (currentlyManipulatedWithMouseWindowId == nil || window.windowId == currentlyManipulatedWithMouseWindowId))
        .andAsync { @Sendable @MainActor in try await getNativeFocusedWindow(.cancellable) == window }
}

/// Same motivation as in monitorFrameNormalized
/// While a mouse-modifier drag is dropped the tap swallows the events, so NSEvent.mouseLocation is stale
@MainActor var mouseLocation: CGPoint { mouseDragDropLocation ?? NSEvent.mouseLocation.withYAxisFlipped }
