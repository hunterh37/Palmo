import Foundation

// MARK: - Protocol

/// Writes the prose layer for a batch of projects. Implementations differ only
/// in *where* the text comes from (on-device Foundation Models, OpenRouter, or
/// deterministic templates) — never in what counts as truth, which is decided
/// by `PulseFactsBuilder`.
///
/// Returns narration keyed by project `cwd`. A missing key means "use the
/// template fallback for that project", so callers never have to special-case
/// partial results.
protocol PulseNarrator {
    func narrate(_ facts: [ProjectFacts]) async -> [String: ProjectNarration]
}

// MARK: - Template narrator (no LLM, always available)

/// The zero-dependency fallback: deterministic prose straight from the facts.
/// Offline, instant, and impossible to get "wrong". This is the floor the
/// whole feature stands on — every other narrator falls back to it.
struct TemplateNarrator: PulseNarrator {
    func narrate(_ facts: [ProjectFacts]) async -> [String: ProjectNarration] {
        var out: [String: ProjectNarration] = [:]
        for f in facts {
            out[f.cwd] = PulseFactsBuilder.templateNarration(for: f)
        }
        return out
    }
}

// MARK: - Shared prompt + parsing (used by the LLM narrators)

/// Prompt construction and lenient JSON parsing shared by the Foundation
/// Models and OpenRouter narrators. Kept here so both cloud and on-device
/// paths produce and consume exactly the same schema.
enum PulseNarrationIO {

    /// System instruction: the model writes *prose only*, never state.
    static let system = """
    You narrate the status of software projects for a friendly on-screen \
    assistant. For each project you are given its derived state and some git \
    facts. Write a short, warm status line. Respond with ONLY a JSON object of \
    the shape {"projects":[{"cwd":"...","headline":"...","detail":"..."}]}. \
    "headline" is at most 6 words. "detail" is one short sentence. Do not \
    invent facts, do not change the state, no markdown, no prose outside JSON.
    """

    /// Build the user prompt describing every project's facts + derived state.
    static func userPrompt(for facts: [ProjectFacts]) -> String {
        var rows: [String] = []
        for f in facts {
            let state = PulseFactsBuilder.state(from: f)
            var lines = ["cwd: \(f.cwd)",
                         "name: \(f.name)",
                         "state: \(state.rawValue)"]
            if !f.recentCommit.isEmpty {
                lines.append("latest commit: \(f.recentCommit)")
            }
            if f.recentCommits.count > 1 {
                let more = f.recentCommits.dropFirst().prefix(3).joined(separator: "; ")
                if !more.isEmpty { lines.append("earlier commits: \(more)") }
            }
            if f.isDirty { lines.append("uncommitted files: \(f.dirtyCount)") }
            if f.hasLiveSession {
                lines.append("live session: \(f.sessionDone ? "finished, awaiting reply" : "running")")
            }
            if !f.sessionLastMessage.isEmpty {
                lines.append("claude last said: \(f.sessionLastMessage.prefix(280))")
            }
            rows.append(lines.joined(separator: "\n"))
        }
        return "Projects:\n\n" + rows.joined(separator: "\n\n")
    }

    /// Parse the model's JSON into narration keyed by cwd. Lenient about extra
    /// keys/whitespace; silently drops malformed rows so the caller falls back
    /// to templates for those projects.
    static func parse(_ content: String) -> [String: ProjectNarration] {
        let cleaned = OpenRouterClient.stripFences(content)
        guard let data = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["projects"] as? [[String: Any]]
        else { return [:] }
        var out: [String: ProjectNarration] = [:]
        for row in rows {
            guard let cwd = (row["cwd"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty
            else { continue }
            let headline = (row["headline"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = (row["detail"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !headline.isEmpty else { continue }
            out[cwd] = ProjectNarration(headline: headline, detail: detail)
        }
        return out
    }
}
