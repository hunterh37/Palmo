import SwiftUI

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
