import Foundation

/// Single touchpoint for the Project Pulse feature. Enabling it from the host
/// app is one line:
///
///     ProjectPulseModule.activate(registry: projectRegistry, sessions: claudeSessions)
///
/// which injects the app's shared stores into `ProjectPulseEngine.shared` and
/// starts observing them. The engine then publishes `$pulses`, consumed by
/// `HandMenuModel` and the briefing overlay. Everything else in the module is
/// internal to `Sources/ProjectPulse/`.
@MainActor
enum ProjectPulseModule {
    /// Wire the shared engine to the app's registry + session store, and hook
    /// the narrator up to live settings (on-device / OpenRouter / auto).
    static func activate(registry: ProjectRegistry, sessions: ClaudeSessionStore) {
        let engine = ProjectPulseEngine.shared
        engine.narratorProvider = { NarratorFactory.make(from: AppSettings.shared) }
        engine.configure(registry: registry, sessions: sessions)
    }
}
