import SwiftUI
import AppKit

/// Applies "notch mode" to the main window: an always-on-top, borderless-feeling
/// overlay pinned flush to the top-center edge of the screen. The window is sized
/// to the fully-expanded panel; SwiftUI animates the webcam view dropping down from
/// the top edge (Dynamic-Island style), while this styler hides the window
/// (click-through + alpha 0) whenever the panel is fully retracted.
/// Restores the previous frame/level when un-collapsed.
@MainActor
final class CollapseWindowStyler {
    static let shared = CollapseWindowStyler()

    /// Size of the notch overlay window (matches the fully-expanded panel).
    static let collapsedSize = NSSize(width: 480, height: 320)
    /// Margin used only to clamp the window off the very screen edges if needed.
    static let margin: CGFloat = 12

    private weak var window: NSWindow?
    private var savedFrame: NSRect?
    private var savedStyleMask: NSWindow.StyleMask?
    private var isCollapsed = false
    /// Whether the panel is currently expanded (a hand is present). Drives
    /// click-through + window alpha so a retracted notch never steals clicks.
    private var isExpanded = false

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

    /// Toggles the window between "hidden notch" (no hand) and "visible panel"
    /// (hand present). The height animation itself lives in SwiftUI; here we only
    /// hide the window's alpha and make it click-through when fully retracted so
    /// the transparent top-center band never intercepts clicks meant for apps
    /// underneath.
    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        guard isCollapsed, let window else { return }
        window.ignoresMouseEvents = !expanded
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = expanded ? 0.35 : 0.5
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = expanded ? 1 : 0
        }
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
            // Start fully hidden + click-through; a detected hand flips this via
            // setExpanded(). SwiftUI clips the panel to a bottom-rounded notch.
            isExpanded = false
            window.ignoresMouseEvents = true
            window.alphaValue = 0
        } else {
            window.level = .normal
            isExpanded = false
            window.ignoresMouseEvents = false
            window.alphaValue = 1
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
            // SwiftUI re-applies its own sizing constraints when the collapse
            // state flips, which can stomp the animated restore — re-assert.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, !self.isCollapsed, let window = self.window else { return }
                if window.frame != target {
                    window.setFrame(target, display: true, animate: false)
                }
            }
        }
    }

    /// Pins the notch window flush to the top-center of the active screen's
    /// visible frame (just under the menu bar), so the panel drops straight down.
    private func collapsedFrame(for window: NSWindow) -> NSRect {
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = Self.collapsedSize
        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height,
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
