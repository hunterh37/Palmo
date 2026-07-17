import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

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
            // Wait for the frame animation so the mask is sized to the final
            // content bounds.
            let delay = animated ? 0.30 : 0.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isCollapsed else { return }
                self.applyFeatherMask(true)
            }
            dreamFadeIn()
        } else {
            applyFeatherMask(false)
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

    // MARK: - Dream feather

    /// Masks the content view's layer with a pre-blurred rounded rect, so the
    /// video feathers out into transparency, then adds a slow "breathing"
    /// scale animation to the mask so the edge drifts like a dream.
    private func applyFeatherMask(_ enable: Bool) {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        guard let layer = contentView.layer else { return }
        if enable {
            let size = contentView.bounds.size
            let mask = CALayer()
            mask.contents = Self.featherImage(size: size)
            mask.frame = CGRect(origin: .zero, size: size)
            mask.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            mask.position = CGPoint(x: size.width / 2, y: size.height / 2)

            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 1.0
            breathe.toValue = 1.045
            breathe.duration = 2.6
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            mask.add(breathe, forKey: "breathe")

            layer.mask = mask
        } else {
            layer.mask = nil
        }
    }

    /// Fades the whole window in from nothing, like the overlay is
    /// materializing out of the corner.
    private func dreamFadeIn() {
        guard let window else { return }
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 1.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    /// White rounded rect, gaussian-blurred, rendered once as the alpha mask.
    private static func featherImage(size: CGSize) -> CGImage? {
        let scale: CGFloat = 2
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let inset: CGFloat = 30 * scale
        let rect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
            .insetBy(dx: inset, dy: inset)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 40 * scale,
                           cornerHeight: 40 * scale, transform: nil))
        ctx.fillPath()
        guard let hard = ctx.makeImage() else { return nil }

        let blurred = CIImage(cgImage: hard)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 12 * scale)
        return CIContext().createCGImage(
            blurred, from: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
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
