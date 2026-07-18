import Foundation

/// Delivers a chosen reply into a specific Claude Code session by POSTing it to
/// that session's local Palmo channel (an MCP "channel" server the session was
/// launched with). The channel then injects the text as a `<channel>` prompt.
///
/// Routing: each Palmo-launched session binds a unique localhost port
/// (PALMO_PORT), which the hook mirrors into the session JSON, so we know
/// exactly which port reaches which session. No window focusing, no keystrokes.
struct ClaudeReplySender {
    /// Identifies us to the channel's sender allowlist.
    static let senderID = "palmo_app"

    enum SendError: Error, LocalizedError {
        case noPort
        case badStatus(Int)

        var errorDescription: String? {
            switch self {
            case .noPort:
                return "This session wasn't launched through Palmo, so there's no channel to send to."
            case .badStatus(let code):
                return "The session's channel rejected the message (HTTP \(code))."
            }
        }
    }

    /// Fire the reply at the session's channel. `port` comes from the session's
    /// hook JSON; nil means the session can't receive sends.
    @discardableResult
    func send(text: String, sessionID: String, port: Int?) async throws -> Bool {
        guard let port else { throw SendError.noPort }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)")!)
        request.httpMethod = "POST"
        request.setValue(Self.senderID, forHTTPHeaderField: "X-Sender")
        request.setValue(sessionID, forHTTPHeaderField: "X-Session")
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = text.data(using: .utf8)
        request.timeoutInterval = 5

        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SendError.badStatus(http.statusCode)
        }
        return true
    }
}
