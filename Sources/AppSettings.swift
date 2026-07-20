import SwiftUI
import ServiceManagement
import CoreGraphics

/// Persistent user settings, backed by UserDefaults, published for UI + engines.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    // MARK: Gestures & pointer

    @Published var cursorSensitivity: CGFloat {
        didSet { d.set(Double(cursorSensitivity), forKey: "cursorSensitivity") }
    }
    @Published var pinchClickEnabled: Bool {
        didSet { d.set(pinchClickEnabled, forKey: "pinchClickEnabled") }
    }
    @Published var scrollGestureEnabled: Bool {
        didSet { d.set(scrollGestureEnabled, forKey: "scrollGestureEnabled") }
    }
    @Published var scrollSpeed: CGFloat {
        didSet { d.set(Double(scrollSpeed), forKey: "scrollSpeed") }
    }

    // MARK: Air commands

    @Published var peaceCommand: AirCommand {
        didSet { d.set(peaceCommand.rawValue, forKey: "peaceCommand") }
    }
    @Published var thumbsUpCommand: AirCommand {
        didSet { d.set(thumbsUpCommand.rawValue, forKey: "thumbsUpCommand") }
    }
    @Published var voiceReactions: Bool {
        didSet { d.set(voiceReactions, forKey: "voiceReactions") }
    }
    /// Instant camera kill switch — pauses all tracking.
    @Published var trackingPaused: Bool = false

    // MARK: Assistant

    /// User-supplied Anthropic API key (stored locally; the app is distributed
    /// outside the App Store and calls the API directly).
    @Published var anthropicKey: String {
        didSet { d.set(anthropicKey, forKey: "anthropicKey") }
    }

    // MARK: Ticket suggestions

    /// OpenRouter API key used to generate ticket suggestions (stored locally;
    /// the app is distributed outside the App Store and calls the API directly).
    @Published var openRouterKey: String {
        didSet { d.set(openRouterKey, forKey: "openRouterKey") }
    }
    /// OpenRouter model slug used for ticket generation.
    @Published var openRouterModel: String {
        didSet { d.set(openRouterModel, forKey: "openRouterModel") }
    }
    /// Master switch for the ticket-suggestion feature (opt-in).
    @Published var ticketSuggestionsEnabled: Bool {
        didSet { d.set(ticketSuggestionsEnabled, forKey: "ticketSuggestionsEnabled") }
    }

    // MARK: General

    @Published var onboardingDone: Bool {
        didSet { d.set(onboardingDone, forKey: "onboardingDone") }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            d.set(launchAtLogin, forKey: "launchAtLogin")
            applyLaunchAtLogin()
        }
    }

    /// Bundle IDs shown on the orb ring (max 8).
    @Published var orbBundleIDs: [String] {
        didSet { d.set(orbBundleIDs, forKey: "orbAppBundleIDs") }
    }

    private init() {
        cursorSensitivity = d.object(forKey: "cursorSensitivity") as? Double ?? 2.4
        pinchClickEnabled = d.object(forKey: "pinchClickEnabled") as? Bool ?? true
        scrollGestureEnabled = d.object(forKey: "scrollGestureEnabled") as? Bool ?? true
        scrollSpeed = d.object(forKey: "scrollSpeed") as? Double ?? 1.0
        peaceCommand = AirCommand(rawValue: d.string(forKey: "peaceCommand") ?? "") ?? .screenshot
        thumbsUpCommand = AirCommand(rawValue: d.string(forKey: "thumbsUpCommand") ?? "") ?? .playPause
        voiceReactions = d.object(forKey: "voiceReactions") as? Bool ?? false
        anthropicKey = d.string(forKey: "anthropicKey") ?? ""
        openRouterKey = d.string(forKey: "openRouterKey") ?? ""
        openRouterModel = d.string(forKey: "openRouterModel") ?? "anthropic/claude-sonnet-4.5"
        ticketSuggestionsEnabled = d.object(forKey: "ticketSuggestionsEnabled") as? Bool ?? false
        onboardingDone = d.bool(forKey: "onboardingDone")
        launchAtLogin = d.bool(forKey: "launchAtLogin")
        let stored = d.stringArray(forKey: "orbAppBundleIDs") ?? []
        orbBundleIDs = stored.isEmpty ? MenuAction.defaultBundleIDs : stored
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Launch at login change failed: \(error)")
        }
    }
}
