import Foundation
import AppKit
import SceneKit
import Metal

/// Dev tool: renders the real Palmo avatar (the same procedural SceneKit hand
/// used in the app) onto a brand gradient plate and writes a 1024×1024 PNG for
/// the app icon. Triggered by launching the app with `PALMO_ICON_OUT=/path`;
/// it writes the file and exits before any UI or camera starts.
enum IconExporter {
    @MainActor
    static func exportIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["PALMO_ICON_OUT"], !out.isEmpty else { return }
        if let rep = composeIcon(size: 1024),
           let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: out))
            FileHandle.standardError.write(Data("Palmo icon written to \(out)\n".utf8))
        }
        exit(0)
    }

    /// Snapshot the avatar scene with a transparent background.
    @MainActor
    static func renderAvatar(size: CGFloat) -> NSImage {
        let coord = PalmoAvatarView.Coordinator()
        let scene = coord.buildScene()
        coord.apply(mood: .happy, gaze: .zero, waving: false)
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = false
        return renderer.snapshot(atTime: 0,
                                 with: CGSize(width: size, height: size),
                                 antialiasingMode: .multisampling4X)
    }

    /// Gradient rounded plate + centered avatar, drawn at exact pixel size.
    @MainActor
    static func composeIcon(size: CGFloat) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx

        // Squircle plate inset from the edges (the .icns carries its own
        // margin + rounded corners; the OS does not add them).
        let inset = size * 0.085
        let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let radius = rect.width * 0.2237
        let plate = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        plate.addClip()

        // Diagonal brand gradient (Brand.accent → Brand.accentSecondary).
        let c1 = NSColor(calibratedRed: 0.45, green: 0.55, blue: 1.0, alpha: 1)
        let c2 = NSColor(calibratedRed: 0.85, green: 0.45, blue: 0.95, alpha: 1)
        NSGradient(colors: [c1, c2])?.draw(in: rect, angle: -55)

        // Soft top-center light bloom.
        let hi = CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.18)
        NSGradient(colors: [NSColor(white: 1, alpha: 0.30), NSColor(white: 1, alpha: 0)])?
            .draw(fromCenter: hi, radius: 0, toCenter: hi, radius: rect.width * 0.62, options: [])

        // The real Palmo avatar, centered and enlarged a touch.
        let avatar = renderAvatar(size: size)
        let aw = rect.width * 0.86
        let box = CGRect(x: rect.midX - aw / 2,
                         y: rect.midY - aw / 2 + rect.height * 0.01,
                         width: aw, height: aw)
        avatar.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)

        NSGraphicsContext.restoreGraphicsState() // drop plate clip

        // Subtle inner rim for definition.
        NSColor(white: 1, alpha: 0.10).setStroke()
        plate.lineWidth = size * 0.006
        plate.stroke()

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
