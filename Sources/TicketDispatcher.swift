import Foundation
import AppKit

/// Routes a grabbed ticket to Claude Code in the right project directory:
/// into a live Palmo-launched session's channel when one exists for that cwd,
/// otherwise by opening Terminal running Claude in the project directory.
@MainActor
struct TicketDispatcher {
    private let replySender = ClaudeReplySender()

    enum DispatchError: Error, LocalizedError {
        case scriptFailed(String)
        var errorDescription: String? {
            switch self {
            case .scriptFailed(let msg): return "Couldn't open Terminal: \(msg)"
            }
        }
    }

    /// Sends the ticket. Returns a short human summary for the toast.
    func dispatch(_ ticket: Ticket, sessions: [ClaudeSession]) async throws -> String {
        let target = (ticket.projectCwd as NSString).standardizingPath
        let name = (target as NSString).lastPathComponent

        // Prefer a live session already working in this project.
        if let session = sessions.first(where: {
            ($0.cwd as NSString).standardizingPath == target && $0.canSend
        }) {
            try await replySender.send(text: ticket.prompt,
                                       sessionID: session.id, port: session.port)
            return "Sent to \(name)'s session"
        }

        try launchTerminal(cwd: target, prompt: ticket.prompt)
        return "Started Claude in \(name)"
    }

    /// Opens Terminal in the project dir running Claude with the ticket prompt.
    /// Uses the Palmo wrapper when available so the new session gets a channel.
    private func launchTerminal(cwd: String, prompt: String) throws {
        let launcher = Self.claudeLauncher()
        let command = "cd \(Self.shellQuote(cwd)) && \(launcher) \(Self.shellQuote(String(prompt.prefix(4000))))"
        let scriptSource = """
        tell application "Terminal"
            do script "\(Self.appleScriptQuote(command))"
            activate
        end tell
        """
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: scriptSource) else {
            throw DispatchError.scriptFailed("bad script")
        }
        script.executeAndReturnError(&errorInfo)
        if let errorInfo, let message = errorInfo[NSAppleScript.errorMessage] as? String {
            throw DispatchError.scriptFailed(message)
        }
    }

    /// Prefer the user's palmo-claude wrapper (checkout or PATH) so the new
    /// session binds a channel port; fall back to plain `claude`.
    static func claudeLauncher() -> String {
        let candidates = [
            ("~/dev/handorbmenu/palmo-channel/palmo-claude" as NSString).expandingTildeInPath,
            ("~/.local/bin/palmo-claude" as NSString).expandingTildeInPath,
            "/usr/local/bin/palmo-claude",
            "/opt/homebrew/bin/palmo-claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return shellQuote(path)
        }
        // Fall back to whatever the shell resolves; plain `claude` still works,
        // it just can't receive channel sends from Palmo afterwards.
        return "$(command -v palmo-claude || echo claude)"
    }

    // MARK: Escaping

    /// Single-quote shell escaping: ' → '\''.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a string for embedding inside an AppleScript double-quoted literal.
    static func appleScriptQuote(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
