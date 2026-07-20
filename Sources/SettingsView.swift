import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Branded settings window: General, Gestures, Orb Menu, Assistant, Claude Code, About.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            gestures.tabItem { Label("Gestures", systemImage: "hand.raised") }
            orbMenu.tabItem { Label("Orb Menu", systemImage: "circle.hexagongrid") }
            assistant.tabItem { Label("Assistant", systemImage: "sparkles") }
            ClaudeCodeSettings().tabItem { Label("Claude Code", systemImage: "terminal") }
            TicketSettings().tabItem { Label("Tickets", systemImage: "lightbulb") }
            about.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 440, height: 360)
    }

    private var general: some View {
        Form {
            Toggle("Start \(Brand.name) at login", isOn: $settings.launchAtLogin)
            Section {
                Text("Hand tracking runs entirely on this Mac using Apple's Vision framework. Camera frames are never uploaded or stored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Privacy", systemImage: "lock.shield")
            }
        }
        .formStyle(.grouped)
    }

    private var gestures: some View {
        Form {
            Section("Pointer") {
                VStack(alignment: .leading) {
                    Slider(value: $settings.cursorSensitivity, in: 1.0...4.5) {
                        Text("Cursor speed")
                    }
                    Text("How far the cursor travels per hand movement")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Pinch-tap to click", isOn: $settings.pinchClickEnabled)
            }
            Section("Scrolling") {
                Toggle("Fist scroll gesture", isOn: $settings.scrollGestureEnabled)
                if settings.scrollGestureEnabled {
                    Slider(value: $settings.scrollSpeed, in: 0.3...2.5) {
                        Text("Scroll speed")
                    }
                }
            }
            Section("Air commands") {
                Picker(selection: $settings.peaceCommand) {
                    ForEach(AirCommand.allCases) { c in
                        Label(c.label, systemImage: c.icon).tag(c)
                    }
                } label: {
                    Text("✌️ Peace sign")
                }
                Picker(selection: $settings.thumbsUpCommand) {
                    ForEach(AirCommand.allCases) { c in
                        Label(c.label, systemImage: c.icon).tag(c)
                    }
                } label: {
                    Text("👍 Thumbs up")
                }
                Toggle("\(Brand.name) speaks when things happen", isOn: $settings.voiceReactions)
            }
        }
        .formStyle(.grouped)
    }

    private var orbMenu: some View {
        OrbMenuEditor()
    }

    private var assistant: some View {
        Form {
            Section("On-device intelligence") {
                Label("\(Brand.name) chats using Apple's on-device foundation model. Free, offline, and 100% private — conversations never leave this Mac.",
                      systemImage: "cpu")
                    .font(.callout)
                Text("Requires Apple Intelligence to be enabled in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var about: some View {
        VStack(spacing: 10) {
            BuddyView(mood: .happy).frame(width: 72, height: 72)
            Text(Brand.name)
                .font(.system(.title, design: .rounded).weight(.bold))
            Text("Version \(Brand.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Brand.blurb)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 30)
            Link(Brand.website.replacingOccurrences(of: "https://", with: ""),
                 destination: URL(string: Brand.website)!)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Claude Code integration: install the hooks that let Palmo show an orb
/// per active Claude Code session in collapsed mode.
private struct ClaudeCodeSettings: View {
    @State private var installed = ClaudeSessionStore.checkHooksInstalled()
    @State private var error: String?

    var body: some View {
        Form {
            Section("Session orbs") {
                Label("When \(Brand.name) is collapsed, each active Claude Code session appears as an orb. Orange means working, green means finished. Hold a fist for 1 second to float the orbs up, then point at one for 1 second to check it off.",
                      systemImage: "circle.hexagongrid.fill")
                    .font(.callout)
            }
            Section("Hooks") {
                HStack {
                    Image(systemName: installed ? "checkmark.circle.fill"
                                                : "exclamationmark.circle")
                        .foregroundStyle(installed ? .green : .orange)
                    Text(installed ? "Claude Code hooks installed"
                                   : "Hooks not installed")
                    Spacer()
                    Button(installed ? "Reinstall" : "Install hooks") {
                        install()
                    }
                }
                Text("Adds SessionStart, UserPromptSubmit, Stop, and SessionEnd hooks to ~/.claude/settings.json. Existing hooks are kept. Restart running Claude Code sessions to pick them up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func install() {
        do {
            try ClaudeSessionStore().installHooks()
            installed = true
            error = nil
        } catch {
            self.error = "Install failed: \(error.localizedDescription)"
        }
    }
}

/// Ticket suggestions: OpenRouter key/model + the auto-registered project list.
private struct TicketSettings: View {
    @EnvironmentObject private var model: HandMenuModel

    var body: some View {
        TicketSettingsForm(registry: model.projects)
    }
}

private struct TicketSettingsForm: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var registry: ProjectRegistry

    var body: some View {
        Form {
            Section("Ticket suggestions") {
                Toggle("Suggest tickets to grab", isOn: $settings.ticketSuggestionsEnabled)
                Text("After a Claude Code session finishes (or a new commit lands), \(Brand.name) proposes tickets to work on next. Pinch one out of the air and drop it on the ring to start Claude on it in that project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if settings.ticketSuggestionsEnabled {
                Section("OpenRouter") {
                    SecureField("API key", text: $settings.openRouterKey)
                    TextField("Model", text: $settings.openRouterModel)
                    Text("Suggestions are generated via OpenRouter using recent commits, the working tree, and any tickets/ folder in the repo. Stored locally.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Projects") {
                    if registry.projects.isEmpty {
                        Text("No projects yet — they're added automatically whenever a Claude Code session runs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(registry.projects) { project in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(project.name)
                                Text(project.cwd)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button {
                                registry.remove(cwd: project.cwd)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Editor for the apps shown on the orb ring (max 8).
private struct OrbMenuEditor: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apps on your hand menu")
                .font(.headline)
            Text("Pinch these in mid-air to launch them. Play/Pause and Ask \(Brand.name) orbs are always included.")
                .font(.caption)
                .foregroundStyle(.secondary)
            List {
                ForEach(settings.orbBundleIDs, id: \.self) { bid in
                    HStack {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable().frame(width: 20, height: 20)
                            Text(FileManager.default.displayName(atPath: url.path)
                                .replacingOccurrences(of: ".app", with: ""))
                        } else {
                            Image(systemName: "questionmark.app")
                            Text(bid).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            settings.orbBundleIDs.removeAll { $0 == bid }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 140)
            HStack {
                Button {
                    addApp()
                } label: {
                    Label("Add app...", systemImage: "plus")
                }
                .disabled(settings.orbBundleIDs.count >= 8)
                Spacer()
                Button("Reset to defaults") {
                    settings.orbBundleIDs = MenuAction.defaultBundleIDs
                }
                .controlSize(.small)
            }
        }
        .padding(14)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.message = "Choose an app for your orb menu"
        if panel.runModal() == .OK, let url = panel.url,
           let bid = Bundle(url: url)?.bundleIdentifier,
           !settings.orbBundleIDs.contains(bid) {
            settings.orbBundleIDs.append(bid)
        }
    }
}
