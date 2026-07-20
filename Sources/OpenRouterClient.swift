import Foundation

/// Minimal OpenRouter chat-completions client used for ticket generation.
/// One-shot, no streaming; the caller owns prompt construction and parsing
/// of the (JSON) content string this returns.
struct OpenRouterClient {
    enum ClientError: Error, LocalizedError, Equatable {
        case noKey
        case badStatus(Int, String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .noKey:
                return "Add an OpenRouter API key in Settings to generate tickets."
            case .badStatus(let code, let body):
                return "OpenRouter error (HTTP \(code)): \(body.prefix(200))"
            case .emptyResponse:
                return "OpenRouter returned an empty response."
            }
        }
    }

    var session: URLSession = .shared

    /// Sends one system+user exchange and returns the assistant content string.
    func complete(system: String, user: String, model: String, apiKey: String,
                  maxTokens: Int = 2000) async throws -> String {
        guard !apiKey.isEmpty else { throw ClientError.noKey }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://dicyaninlabs.com", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Palmo", forHTTPHeaderField: "X-Title")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": system],
                // Cap the user prompt defensively; repo context can be huge.
                ["role": "user", "content": String(user.prefix(24_000))],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ClientError.badStatus(http.statusCode,
                                        String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty
        else { throw ClientError.emptyResponse }
        return Self.stripFences(content)
    }

    /// Removes a wrapping ```json … ``` fence some models add despite
    /// json_object mode, so the result parses as plain JSON.
    static func stripFences(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("```") else { return s }
        s = s.replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
