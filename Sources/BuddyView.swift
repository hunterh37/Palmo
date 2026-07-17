import SwiftUI

/// The buddy's emotional state, driven by hand tracking + assistant activity.
enum BuddyMood {
    case idle        // nothing happening: soft breathing, occasional blink
    case watching    // a hand is visible: eyes track it
    case happy       // pinch / success: squinty smile
    case thinking    // assistant is generating: eyes drift up, dots
}

/// Palmo's face: a squishy gradient blob with expressive eyes.
/// Pure SwiftUI, cheap to render, reusable at any size.
struct BuddyView: View {
    var mood: BuddyMood = .idle
    /// Normalized -1...1 gaze target (where the hand is), x/y.
    var gaze: CGPoint = .zero

    @State private var blink = false
    @State private var breathe = false

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                // Body
                Circle()
                    .fill(
                        RadialGradient(colors: [Brand.accent.opacity(0.95),
                                                Brand.accentSecondary.opacity(0.9)],
                                       center: .init(x: 0.35, y: 0.28),
                                       startRadius: 0, endRadius: s * 0.75)
                    )
                    .shadow(color: Brand.accent.opacity(0.45), radius: s * 0.10, y: s * 0.03)
                    .scaleEffect(breathe ? 1.03 : 0.98)
                    // Scoped to `breathe` only — a bare withAnimation(.repeatForever)
                    // leaks into ancestor transactions (sheet presentation) and makes
                    // the whole window wobble.
                    .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true),
                               value: breathe)

                // Cheeks when happy
                if mood == .happy {
                    HStack(spacing: s * 0.42) {
                        Circle().fill(.pink.opacity(0.45)).frame(width: s * 0.14)
                        Circle().fill(.pink.opacity(0.45)).frame(width: s * 0.14)
                    }
                    .offset(y: s * 0.10)
                    .blur(radius: s * 0.02)
                }

                // Eyes
                HStack(spacing: s * 0.20) {
                    eye(s)
                    eye(s)
                }
                .offset(x: gazeOffset(s).x, y: gazeOffset(s).y - s * 0.05)

                // Mouth
                mouth(s)
                    .offset(y: s * 0.18)

                if mood == .thinking {
                    ThinkingDots()
                        .offset(x: s * 0.34, y: -s * 0.36)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.spring(duration: 0.35), value: mood)
        }
        .onAppear {
            breathe = true
            scheduleBlink()
        }
    }

    private func gazeOffset(_ s: CGFloat) -> CGPoint {
        let target: CGPoint = mood == .thinking ? CGPoint(x: 0.4, y: -0.6) : gaze
        return CGPoint(x: target.x * s * 0.08, y: target.y * s * 0.08)
    }

    @ViewBuilder
    private func eye(_ s: CGFloat) -> some View {
        if mood == .happy {
            // Happy squint: upside-down arc
            Arc()
                .stroke(Color.white, style: StrokeStyle(lineWidth: s * 0.045, lineCap: .round))
                .frame(width: s * 0.16, height: s * 0.09)
        } else {
            Capsule()
                .fill(.white)
                .frame(width: s * 0.11, height: blink ? s * 0.015 : s * 0.20)
        }
    }

    @ViewBuilder
    private func mouth(_ s: CGFloat) -> some View {
        switch mood {
        case .happy:
            RoundedRectangle(cornerRadius: s)
                .fill(.white.opacity(0.95))
                .frame(width: s * 0.26, height: s * 0.13)
                .clipShape(HalfCircleBottom())
        case .thinking:
            Circle().fill(.white.opacity(0.9)).frame(width: s * 0.06)
        default:
            Capsule().fill(.white.opacity(0.9))
                .frame(width: s * 0.14, height: s * 0.035)
        }
    }

    private func scheduleBlink() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Int.random(in: 2...5))) {
            withAnimation(.easeInOut(duration: 0.09)) { blink = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.easeInOut(duration: 0.09)) { blink = false }
                scheduleBlink()
            }
        }
    }
}

/// Upward arc for happy squinted eyes.
private struct Arc: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                       control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.4))
        return p
    }
}

/// Clips a rounded rect into an open-smile lower half.
private struct HalfCircleBottom: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                       control: CGPoint(x: rect.midX, y: rect.maxY * 2))
        return p
    }
}

/// Three bouncing dots shown while the assistant thinks.
struct ThinkingDots: View {
    @State private var phase = false
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(.white.opacity(0.9))
                    .frame(width: 5, height: 5)
                    .offset(y: phase ? -3 : 2)
                    .animation(.easeInOut(duration: 0.45)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.14), value: phase)
            }
        }
        .onAppear { phase = true }
    }
}
