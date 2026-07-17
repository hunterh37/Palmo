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

extension Binding where Value == Bool {
    /// A binding that presents the logical inverse (for "on"-styled toggles
    /// backed by "paused"-styled storage).
    var inverted: Binding<Bool> {
        Binding(get: { !wrappedValue }, set: { wrappedValue = !$0 })
    }
}
