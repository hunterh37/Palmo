import SwiftUI
import AppKit

/// Applies "collapse mode" to the main window: a small, always-on-top,
/// borderless-feeling overlay pinned to the top-right corner of the screen.
/// Restores the previous frame/level when un-collapsed.
@MainActor
final class CollapseWindowStyler {
    static let shared = CollapseWindowStyler()

    /// Size of the collapsed overlay.
    static let collapsedSize = NSSize(width: 340, height: 210)
    /// Margin from the screen's visible-frame edges.
    static let margin: CGFloat = 12

    private weak var window: NSWindow?
    private var savedFrame: NSRect?
    private var savedStyleMask: NSWindow.StyleMask?
    private var isCollapsed = false

    /// Called from a `WindowAccessor` once the SwiftUI content lands in a window.
    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        if isCollapsed { apply(collapsed: true, animated: false) }
    }

    /// Brings the main window to the front (used from the menu bar tray).
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        apply(collapsed: collapsed, animated: true)
    }

    private func apply(collapsed: Bool, animated: Bool) {
        guard let window else { return }
        if collapsed {
            savedFrame = window.frame
            savedStyleMask = window.styleMask

            // Float above everything, on every Space, even over full-screen apps.
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.styleMask.remove(.resizable)
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.isMovableByWindowBackground = true

            // Windowless dream look: fully transparent chrome, no shadow —
            // the SwiftUI layer feathers the video into nothing.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false

            window.setFrame(collapsedFrame(for: window), display: true, animate: animated)
        } else {
            window.level = .normal
            window.collectionBehavior = []
            if let savedStyleMask { window.styleMask = savedStyleMask }
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.standardWindowButton(.closeButton)?.isHidden = false
            window.standardWindowButton(.miniaturizeButton)?.isHidden = false
            window.standardWindowButton(.zoomButton)?.isHidden = false
            window.isMovableByWindowBackground = false

            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.hasShadow = true

            let target = savedFrame ?? defaultRestoredFrame(for: window)
            window.setFrame(target, display: true, animate: animated)
        }
    }

    private func collapsedFrame(for window: NSWindow) -> NSRect {
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = Self.collapsedSize
        return NSRect(
            x: visible.maxX - size.width - Self.margin,
            y: visible.maxY - size.height - Self.margin,
            width: size.width, height: size.height)
    }

    private func defaultRestoredFrame(for window: NSWindow) -> NSRect {
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 960, height: 640)
        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width, height: size.height)
    }
}

/// Invisible view that hands the hosting NSWindow to the styler.
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                CollapseWindowStyler.shared.attach(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            CollapseWindowStyler.shared.attach(window)
        }
    }
}
