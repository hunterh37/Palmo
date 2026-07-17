import SwiftUI

/// Feathered "dream" edge for collapse mode: a blurred rounded-rect mask
/// that slowly breathes, so the video melts into the desktop with no hard
/// window boundary.
struct DreamEdgeMask: View {
    /// 0 → fully hidden, 1 → fully revealed (drives the fade-in).
    var reveal: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            // Slow breathing: the feather softens and tightens like a
            // sleeping thing.
            let pulse = CGFloat(sin(t * 0.8))
            let inset = 22 - 10 * reveal + pulse * 2          // settles ~12
            let blur = (14 + pulse * 4) + (1 - reveal) * 30   // extra soft while fading in
            RoundedRectangle(cornerRadius: 42 + pulse * 4)
                .inset(by: inset)
                .fill(Color.white.opacity(Double(0.15 + 0.85 * reveal)))
                .blur(radius: blur)
        }
    }
}

/// A faint aurora drifting around the feathered edge — screen-blended so it
/// reads as light, not paint.
struct DreamGlow: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                RoundedRectangle(cornerRadius: 36)
                    .inset(by: 16)
                    .strokeBorder(
                        AngularGradient(
                            colors: [
                                .clear, Color.purple.opacity(0.55), .clear,
                                Color.cyan.opacity(0.45), .clear,
                                Color.blue.opacity(0.5), .clear,
                            ],
                            center: .center,
                            angle: .degrees(t * 18)),
                        lineWidth: 10)
                    .blur(radius: 10)
                RoundedRectangle(cornerRadius: 36)
                    .inset(by: 16)
                    .strokeBorder(
                        AngularGradient(
                            colors: [
                                .clear, Color.cyan.opacity(0.35), .clear,
                                Color.pink.opacity(0.3), .clear,
                            ],
                            center: .center,
                            angle: .degrees(-t * 11)),
                        lineWidth: 6)
                    .blur(radius: 6)
            }
            .blendMode(.screen)
        }
        .allowsHitTesting(false)
    }
}
