// Renders the Palmo app icon (buddy face on gradient squircle) to icon_1024.png.
// Run: swift Scripts/render-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

// Rounded-rect background (macOS squircle-ish, with margin per HIG)
let margin = size * 0.09
let rect = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
let bg = NSBezierPath(roundedRect: rect, xRadius: size * 0.2, yRadius: size * 0.2)
bg.addClip()

let colors = [NSColor(calibratedRed: 0.45, green: 0.55, blue: 1.0, alpha: 1).cgColor,
              NSColor(calibratedRed: 0.85, green: 0.45, blue: 0.95, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: margin, y: size - margin),
                       end: CGPoint(x: size - margin, y: margin), options: [])

// Face: soft white highlight blob
ctx.setFillColor(NSColor.white.withAlphaComponent(0.12).cgColor)
ctx.fillEllipse(in: CGRect(x: size * 0.16, y: size * 0.42, width: size * 0.55, height: size * 0.5))

// Eyes (tall white capsules)
func capsule(_ x: CGFloat) {
    let w = size * 0.10, h = size * 0.22
    let r = CGRect(x: x - w / 2, y: size * 0.47, width: w, height: h)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2).fill()
}
capsule(size * 0.40)
capsule(size * 0.60)

// Smile
let smile = NSBezierPath()
smile.move(to: CGPoint(x: size * 0.42, y: size * 0.38))
smile.curve(to: CGPoint(x: size * 0.58, y: size * 0.38),
            controlPoint1: CGPoint(x: size * 0.46, y: size * 0.30),
            controlPoint2: CGPoint(x: size * 0.54, y: size * 0.30))
smile.lineWidth = size * 0.028
smile.lineCapStyle = .round
NSColor.white.setStroke()
smile.stroke()

// Cheeks
NSColor(calibratedRed: 1, green: 0.6, blue: 0.7, alpha: 0.55).setFill()
ctx.fillEllipse(in: CGRect(x: size * 0.28, y: size * 0.40, width: size * 0.07, height: size * 0.05))
ctx.fillEllipse(in: CGRect(x: size * 0.65, y: size * 0.40, width: size * 0.07, height: size * 0.05))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("encode") }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
