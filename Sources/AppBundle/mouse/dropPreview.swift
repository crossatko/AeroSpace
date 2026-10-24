import AppKit
import Common

// Drop preview while a tile is dragged with mouse-modifier: a click-through translucent
// rect over the slot the window will land in. Modelled on Skyland's dropPreview.swift
// (MIT, https://github.com/crossatko/skyland); the colour is the system accent.

@MainActor private var dropPreview: NSPanel? = nil

@MainActor
func showDropPreview(_ rect: CGRect) {
    let panel = dropPreview ?? makeDropPreview()
    let frame = dropPreviewFrame(of: rect, primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
    if panel.frame != frame { panel.setFrame(frame, display: true) }
    if !panel.isVisible { panel.orderFrontRegardless() }
}

@MainActor
func hideDropPreview() {
    dropPreview?.orderOut(nil)
}

@MainActor private func makeDropPreview() -> NSPanel {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.level = .floating
    panel.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
    let accent = NSColor.controlAccentColor
    let view = NSView()
    view.wantsLayer = true
    view.layer?.backgroundColor = accent.withAlphaComponent(0.18).cgColor
    view.layer?.borderColor = accent.withAlphaComponent(0.8).cgColor
    view.layer?.borderWidth = 2
    view.layer?.cornerRadius = 8
    panel.contentView = view
    dropPreview = panel
    return panel
}
