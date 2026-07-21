import Foundation
import Combine

/// Gathers a `ProjectPulse` for every known project by combining git reality
/// (recent commits, dirty tree, HEAD) with Claude session reality (live /
/// finished / awaiting reply), then narrates the prose layer through a
/// `PulseNarrator`.
///
/// Truth is deterministic (`PulseFactsBuilder`); the narrator only writes
/// `headline`/`detail`. Narration is cached per project on its *narratable*
/// state (`PulseFactsBuilder.cacheKey`) so the model is only asked about
/// projects that actually changed — everything else reuses cached prose.
///
/// Wiring: created by `ProjectPulseModule.activate(registry:sessions:)`, which
/// injects the shared `ProjectRegistry` and `ClaudeSessionStore` rather than
/// creating new ones. `HandMenuModel` reads `$pulses`.
@MainActor
final class ProjectPulseEngine: ObservableObject {
    static let shared = ProjectPulseEngine()

    /// Display-ready readings, most urgent first.
    @Published private(set) var pulses: [ProjectPulse] = []
    @Published private(set) var isRefreshing = false

    /// Aggregate mood for the Palmo mascot during a briefing.
    var aggregateMood: BuddyMood {
        if pulses.contains(where: { $0.state == .needsYou || $0.state == .blocked }) {
            return .watching
        }
        if pulses.contains(where: { $0.state == .working }) { return .thinking }
        if !pulses.isEmpty, pulses.allSatisfy({ $0.state == .done || $0.state == .idle }) {
            return .happy
        }
        return .idle
    }

    /// Count of projects that want the user's attention (entry-orb badge).
    var attentionCount: Int { pulses.filter { $0.state.wantsAttention }.count }

    // Injected dependencies (set in `configure`).
    private weak var registry: ProjectRegistry?
    private weak var sessions: ClaudeSessionStore?

    /// Narrator supplier — indirected so M6 can swap in the on-device /
    /// OpenRouter factory without touching the engine. Defaults to templates.
    var narratorProvider: () -> PulseNarrator = { TemplateNarrator() }

    /// Per-project narration cache keyed on narratable state.
    private var cache: [String: (key: String, narration: ProjectNarration)] = [:]

    private var cancellables: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?
    private var debounce: Task<Void, Never>?

    private let fileURL: URL
    /// Max projects surfaced as bubbles at once (kept small for the stack).
    private let maxProjects = 8

    init(fileURL: URL = ClaudeSessionStore.supportDir.appendingPathComponent("project-pulses.json")) {
        self.fileURL = fileURL
        loadPersisted()
    }

    /// Inject the shared stores and begin observing them. Idempotent.
    func configure(registry: ProjectRegistry, sessions: ClaudeSessionStore) {
        self.registry = registry
        self.sessions = sessions
        cancellables.removeAll()

        // Coalesce bursts of registry/session churn into a single refresh.
        registry.$projects
            .combineLatest(sessions.$sessions)
            .sink { [weak self] _, _ in self?.scheduleRefresh() }
            .store(in: &cancellables)

        scheduleRefresh()
    }

    /// Debounced trigger — collapses rapid 1s polling ticks into one refresh.
    func scheduleRefresh(after seconds: Double = 0.4) {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            self?.refresh()
        }
    }

    /// Rebuild all pulses now.
    func refresh() {
        guard let registry, let sessions else { return }
        // Snapshot inputs on the main actor before hopping off for git I/O.
        let projects = Array(registry.projects.prefix(maxProjects))
        let sessionList = sessions.sessions
        guard !projects.isEmpty else {
            if !pulses.isEmpty { pulses = [] }
            return
        }

        refreshTask?.cancel()
        isRefreshing = true
        let provider = narratorProvider
        refreshTask = Task { [weak self] in
            let facts = await Self.gatherFacts(projects: projects, sessions: sessionList)
            if Task.isCancelled { return }
            await self?.apply(facts: facts, narratorProvider: provider)
        }
    }

    // MARK: - Facts gathering (off main)

    /// Build `ProjectFacts` for each project. Git runs off-main via `GitRunner`.
    nonisolated static func gatherFacts(projects: [Project],
                                        sessions: [ClaudeSession]) async -> [ProjectFacts] {
        var out: [ProjectFacts] = []
        for project in projects {
            let cwd = project.cwd
            // Newest live session for this cwd, if any.
            let session = sessions
                .filter { ($0.cwd as NSString).standardizingPath == cwd }
                .max { $0.updatedAt < $1.updatedAt }

            async let logOut = GitRunner.run(cwd: cwd, args: ["log", "--oneline", "-5", "--format=%s"])
            async let statusOut = GitRunner.run(cwd: cwd, args: ["status", "--porcelain"])
            let (log, status) = await (logOut, statusOut)

            let commits = log.split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let dirtyCount = status.split(separator: "\n").filter { !$0.isEmpty }.count
            let head = ProjectRegistry.currentHead(cwd: cwd)

            let updatedAt = max(project.lastActivity, session?.updatedAt ?? .distantPast)

            out.append(ProjectFacts(
                cwd: cwd,
                name: project.name,
                head: head,
                recentCommits: commits,
                dirtyCount: dirtyCount,
                hasLiveSession: session != nil,
                sessionDone: session?.isDone ?? false,
                sessionLastMessage: session?.lastMessage ?? "",
                canSend: session?.canSend ?? false,
                updatedAt: updatedAt))
        }
        return out
    }

    // MARK: - Narrate + publish

    private func apply(facts: [ProjectFacts], narratorProvider: () -> PulseNarrator) async {
        defer { isRefreshing = false }

        // Split into cache hits (reuse prose) and misses (need narration).
        var narration: [String: ProjectNarration] = [:]
        var stale: [ProjectFacts] = []
        for f in facts {
            let key = PulseFactsBuilder.cacheKey(for: f)
            if let hit = cache[f.cwd], hit.key == key {
                narration[f.cwd] = hit.narration
            } else {
                stale.append(f)
            }
        }

        if !stale.isEmpty {
            let fresh = await narratorProvider().narrate(stale)
            if Task.isCancelled { return }
            for f in stale {
                // Fall back to the template for any project the narrator skipped.
                let n = fresh[f.cwd] ?? PulseFactsBuilder.templateNarration(for: f)
                narration[f.cwd] = n
                cache[f.cwd] = (key: PulseFactsBuilder.cacheKey(for: f), narration: n)
            }
        }

        // Drop cache entries for projects that no longer exist.
        let liveCwds = Set(facts.map(\.cwd))
        cache = cache.filter { liveCwds.contains($0.key) }

        let built = facts
            .map { PulseFactsBuilder.pulse(from: $0, narration: narration[$0.cwd] ?? PulseFactsBuilder.templateNarration(for: $0)) }
            .sorted {
                $0.state.sortRank != $1.state.sortRank
                    ? $0.state.sortRank < $1.state.sortRank
                    : $0.updatedAt > $1.updatedAt
            }

        if built != pulses {
            pulses = built
            persist(built)
        }
    }

    // MARK: - Persistence

    private func loadPersisted() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ProjectPulse].self, from: data)
        else { return }
        pulses = decoded
    }

    private func persist(_ pulses: [ProjectPulse]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(pulses) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
