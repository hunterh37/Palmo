import Foundation

// MARK: - State

/// The derived, deterministic state of a project. The *truth* about a project
/// is computed here from git + session facts — never from the language model,
/// which only ever writes the prose (`headline`/`detail`).
///
/// `sortRank` orders the bubble stack (lower = higher / more urgent).
enum PulseState: String, Codable, CaseIterable, Equatable {
    /// A session finished its turn and is waiting for the user.
    case needsYou
    /// A session is actively running right now.
    case working
    /// Uncommitted work sitting in the tree with no live session.
    case blocked
    /// At rest: work committed, tree clean, no live session.
    case done
    /// Nothing notable / no recent activity.
    case idle

    /// Stack order — most urgent first.
    var sortRank: Int {
        switch self {
        case .needsYou: return 0
        case .blocked:  return 1
        case .working:  return 2
        case .done:     return 3
        case .idle:     return 4
        }
    }

    /// Short human label for the bubble chip.
    var label: String {
        switch self {
        case .needsYou: return "Needs you"
        case .working:  return "Working"
        case .blocked:  return "Uncommitted"
        case .done:     return "Done"
        case .idle:     return "Idle"
        }
    }

    /// SF Symbol shown on the bubble chip.
    var systemImage: String {
        switch self {
        case .needsYou: return "hand.wave.fill"
        case .working:  return "hourglass"
        case .blocked:  return "exclamationmark.triangle.fill"
        case .done:     return "checkmark.circle.fill"
        case .idle:     return "moon.zzz.fill"
        }
    }

    /// RGB tint (0...1), kept UI-framework-free so models stay pure Foundation.
    /// The view layer wraps this in a `Color`.
    var tint: (r: Double, g: Double, b: Double) {
        switch self {
        case .needsYou: return (0.98, 0.55, 0.15) // amber — attention
        case .working:  return (0.30, 0.68, 1.00) // blue — in motion
        case .blocked:  return (0.95, 0.35, 0.42) // red — stuck
        case .done:     return (0.30, 0.82, 0.48) // green — at rest
        case .idle:     return (0.62, 0.64, 0.72) // grey — quiet
        }
    }

    /// Whether this state should pull the user's eye (drives Palmo's mood and
    /// the entry-orb badge count).
    var wantsAttention: Bool { self == .needsYou || self == .blocked }
}

// MARK: - Facts (raw inputs)

/// Everything known about a project at one moment, gathered from git and the
/// Claude session store. Pure data; the narrator turns a batch of these into
/// prose, and `PulseFactsBuilder` turns each into a `ProjectPulse`.
struct ProjectFacts: Equatable {
    var cwd: String
    var name: String
    /// Resolved HEAD hash, or nil when not a git repo.
    var head: String?
    /// Recent commit subjects, newest first (typically up to 5).
    var recentCommits: [String]
    /// Count of entries reported by `git status --porcelain`.
    var dirtyCount: Int
    /// Whether a live Claude session maps to this cwd.
    var hasLiveSession: Bool
    /// Whether that session has finished its turn (Stop hook fired).
    var sessionDone: Bool
    /// Claude's last assistant message for the session, if any.
    var sessionLastMessage: String
    /// Whether a reply can be routed back into the session.
    var canSend: Bool
    /// Most recent activity timestamp across git/session signals.
    var updatedAt: Date

    var isDirty: Bool { dirtyCount > 0 }
    var recentCommit: String { recentCommits.first ?? "" }
}

// MARK: - Narration (the prose layer)

/// The one-line prose written for a project — the *only* thing the language
/// model contributes. Deterministic facts decide everything else.
struct ProjectNarration: Codable, Equatable {
    /// Big bubble text — kept to ~6 words.
    var headline: String
    /// One-sentence detail shown when a bubble is expanded.
    var detail: String
}

// MARK: - Pulse (facts + state + narration, merged)

/// The full, display-ready reading for one project.
struct ProjectPulse: Identifiable, Codable, Equatable {
    var id: String { cwd }
    var cwd: String
    var name: String
    var state: PulseState
    var headline: String
    var detail: String
    var recentCommit: String
    var isDirty: Bool
    var hasLiveSession: Bool
    var canSend: Bool
    var updatedAt: Date
}

// MARK: - Builder (deterministic truth + fallback prose)

/// Pure, testable logic that turns `ProjectFacts` into a `PulseState`, a
/// no-LLM `ProjectNarration`, and a merged `ProjectPulse`. Also produces the
/// cache key the engine uses to avoid regenerating unchanged projects.
enum PulseFactsBuilder {

    /// Derive the deterministic project state. Order matters: the first
    /// matching rule wins.
    static func state(from f: ProjectFacts) -> PulseState {
        if f.hasLiveSession {
            return f.sessionDone ? .needsYou : .working
        }
        if f.isDirty { return .blocked }
        if !f.recentCommit.isEmpty { return .done }
        return .idle
    }

    /// The deterministic, no-model fallback prose. Always available, offline,
    /// and safe — this is what ships when no narrator is configured or the
    /// model is unavailable.
    static func templateNarration(for f: ProjectFacts) -> ProjectNarration {
        switch state(from: f) {
        case .needsYou:
            return ProjectNarration(
                headline: "Waiting on you",
                detail: "Claude finished its turn and is waiting for your reply.")
        case .working:
            return ProjectNarration(
                headline: "Claude is working",
                detail: "A session is running in this project right now.")
        case .blocked:
            let n = f.dirtyCount
            let files = n == 1 ? "1 file" : "\(n) files"
            return ProjectNarration(
                headline: "Uncommitted changes",
                detail: "\(files) changed but not yet committed.")
        case .done:
            let latest = f.recentCommit.isEmpty ? "the latest commit" : f.recentCommit
            return ProjectNarration(
                headline: "All caught up",
                detail: "Latest: \(latest).")
        case .idle:
            return ProjectNarration(
                headline: "Idle",
                detail: "No recent activity in this project.")
        }
    }

    /// Merge facts + narration into a display-ready pulse. Clamps prose lengths
    /// so a misbehaving model can't blow up the bubble layout.
    static func pulse(from f: ProjectFacts, narration: ProjectNarration) -> ProjectPulse {
        let headline = clampWords(narration.headline, maxWords: 6, maxChars: 42)
        let detail = String(narration.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(160))
        return ProjectPulse(
            cwd: f.cwd,
            name: f.name,
            state: state(from: f),
            headline: headline.isEmpty ? f.name : headline,
            detail: detail,
            recentCommit: f.recentCommit,
            isDirty: f.isDirty,
            hasLiveSession: f.hasLiveSession,
            canSend: f.canSend,
            updatedAt: f.updatedAt)
    }

    /// Convenience: facts straight to a pulse using the template narration.
    static func pulse(from f: ProjectFacts) -> ProjectPulse {
        pulse(from: f, narration: templateNarration(for: f))
    }

    /// Identity of a project's *narratable* state. When this is unchanged the
    /// engine reuses cached prose instead of hitting the model again.
    static func cacheKey(for f: ProjectFacts) -> String {
        [f.head ?? "-",
         String(f.hasLiveSession),
         String(f.sessionDone),
         String(f.dirtyCount),
         f.recentCommit].joined(separator: "|")
    }

    /// Trim a headline to at most `maxWords` words and `maxChars` characters.
    private static func clampWords(_ s: String, maxWords: Int, maxChars: Int) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        let clipped = words.prefix(maxWords).joined(separator: " ")
        return String(clipped.prefix(maxChars))
    }
}
