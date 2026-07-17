import SwiftUI

/// Single source of truth for all forward-facing branding.
/// Rename the product here and every UI surface follows.
enum Brand {
    /// Product name shown everywhere in the UI.
    static let name = "Palmo"
    /// Short tagline used in onboarding / about.
    static let tagline = "Your Mac, in the palm of your hand."
    /// One-line description for About / website copy.
    static let blurb = "A cute, delightful assistant that lives on your Mac — wave to summon it, pinch to launch apps, and chat with it anytime."
    /// Marketing version string surfaced in the UI.
    static let version = "1.0"
    static let website = "https://palmo.app"

    /// Primary accent gradient used across branded chrome.
    static let accent = Color(red: 0.45, green: 0.55, blue: 1.0)
    static let accentSecondary = Color(red: 0.85, green: 0.45, blue: 0.95)
    static var gradient: LinearGradient {
        LinearGradient(colors: [accent, accentSecondary],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Liquid glass design system

/// Full-bleed animated "liquid glass" backdrop: slow-drifting chromatic
/// blobs frosted under an ultra-thin material. All dashboard chrome floats
/// on top of this.
struct LiquidGlassBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    ZStack {
                        blob(Brand.accent, r: w * 0.55)
                            .position(x: w * (0.28 + 0.10 * CGFloat(sin(t * 0.11))),
                                      y: h * (0.22 + 0.08 * CGFloat(cos(t * 0.09))))
                        blob(Brand.accentSecondary, r: w * 0.48)
                            .position(x: w * (0.80 + 0.08 * CGFloat(cos(t * 0.07))),
                                      y: h * (0.72 + 0.10 * CGFloat(sin(t * 0.10))))
                        blob(Color.cyan, r: w * 0.36)
                            .position(x: w * (0.58 + 0.12 * CGFloat(sin(t * 0.05 + 2))),
                                      y: h * (0.35 + 0.12 * CGFloat(cos(t * 0.08 + 1))))
                    }
                    .blur(radius: 90)
                    .opacity(scheme == .dark ? 0.42 : 0.30)
                }
            }
            Rectangle().fill(.ultraThinMaterial)
        }
        .ignoresSafeArea()
    }

    private func blob(_ color: Color, r: CGFloat) -> some View {
        Circle().fill(color).frame(width: r, height: r)
    }
}

/// A floating Liquid Glass panel — the only container shape used on the
/// dashboard. Uses the native macOS 26 glass material.
struct GlassCard: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .glassEffect(.regular,
                         in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

extension View {
    func glassCard(padding: CGFloat = 16) -> some View {
        modifier(GlassCard(padding: padding))
    }

    /// Micro caption used for every secondary label on the dashboard.
    func microLabel() -> some View {
        font(.system(size: 9, weight: .medium))
            .kerning(1.2)
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
    }
}

extension Binding where Value == Bool {
    /// A binding that presents the logical inverse (for "on"-styled toggles
    /// backed by "paused"-styled storage).
    var inverted: Binding<Bool> {
        Binding(get: { !wrappedValue }, set: { wrappedValue = !$0 })
    }
}
