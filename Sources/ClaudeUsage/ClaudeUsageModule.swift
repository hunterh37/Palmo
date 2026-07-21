import SwiftUI

// MARK: - Claude Usage module — integration facade
//
// This file is the ONLY thing the host app needs to touch. Everything else in
// `Sources/ClaudeUsage/` is internal to the module.
//
// Integration (two lines in HandOrbMenuApp.swift):
//
//   1. Add the scene to the app body:
//          ClaudeUsageModule.menuBar
//
//   2. Activate the notch overlay once at launch, e.g. on ContentView:
//          .task { ClaudeUsageModule.activate() }
//
// The module owns its own singletons (`UsageEngine.shared`,
// `NotchController.shared`), persists to the shared HandOrbMenu support
// directory, and stores the notch toggle in UserDefaults. Removing the two
// lines above fully disables the module.

@MainActor
enum ClaudeUsageModule {
    /// Wire the notch overlay to the usage engine. Idempotent-ish: call once at
    /// launch on the main actor. Also kicks off the engine's background scan
    /// loop (the engine starts scanning as soon as it is first referenced).
    static func activate() {
        NotchController.shared.attach(engine: .shared)
    }

    /// A ready-to-use menu-bar item showing the per-account usage bars popover.
    /// Drop `ClaudeUsageModule.menuBar` directly into the app's `Scene` body.
    static var menuBar: some Scene { ClaudeUsageMenuBar() }
}

/// The menu-bar scene that hosts the usage popover. Kept separate so the host
/// app can either use `ClaudeUsageModule.menuBar` or embed `ClaudeUsageView`
/// wherever it likes.
@MainActor
struct ClaudeUsageMenuBar: Scene {
    @StateObject private var engine = UsageEngine.shared
    @StateObject private var notch = NotchController.shared

    var body: some Scene {
        MenuBarExtra {
            ClaudeUsageView()
                .environmentObject(engine)
                .environmentObject(notch)
        } label: {
            // SF Symbol + the live current-account title (e.g. "hunter 42%").
            Image(systemName: "gauge.with.dots.needle.33percent")
            Text(engine.menuTitle)
        }
        .menuBarExtraStyle(.window)
    }
}
