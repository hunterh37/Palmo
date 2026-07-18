import SwiftUI

/// A cute, delightful assistant for your Mac. Watches the webcam for your
/// hand: wave to summon a 3D orb menu, pinch to launch apps or click, make a
/// fist to scroll — and chat with the buddy anytime.
@main
struct HandOrbMenuApp: App {
    @StateObject private var model = HandMenuModel()
    @ObservedObject private var settings = AppSettings.shared

    init() {
        // Dev-only: `PALMO_ICON_OUT=/path` renders the app icon and exits.
        IconExporter.exportIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task { await model.start() }
                .sheet(isPresented: .constant(!settings.onboardingDone)) {
                    OnboardingView { }
                        .interactiveDismissDisabled()
                }
                .openAssistantWindowBridge()
        }
        .windowResizability(.contentMinSize)

        Window("Chat with \(Brand.name)", id: "assistant-chat") {
            AssistantChatView(assistant: model.assistant)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
        }

        MenuBarExtra(Brand.name, systemImage: "hand.raised.circle.fill") {
            MenuBarView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Opens the chat window when an "Ask" orb is pinched (posted via
/// NotificationCenter, since the orb engine has no environment access).
private struct OpenAssistantBridge: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .openAssistant)) { _ in
            openWindow(id: "assistant-chat")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

extension View {
    func openAssistantWindowBridge() -> some View {
        modifier(OpenAssistantBridge())
    }
}
