import Foundation

// MARK: - Model

/// One suggested unit of work for a project, ready to hand to Claude Code.
struct Ticket: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var detail: String
    /// The full prompt to send to Claude Code when the ticket is grabbed.
    var prompt: String
    /// 1 (high) ... 3 (low).
    var priority: Int
    /// Standardized path of the project this ticket belongs to.
    var projectCwd: String
}

// MARK: - Git helper

/// Runs a git (or other) command with a hard timeout, off the main actor.
/// Returns "" on any failure — callers treat context as best-effort.
enum GitRunner {
    static func run(cwd: String, executable: String = "/usr/bin/git",
                    args: [String], timeout: TimeInterval = 5,
                    maxOutput: Int = 6000) async -> String {
        guard !cwd.isEmpty else { return "" }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                process.arguments = args
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: "")
                    return
                }
                // Hard kill if the command wedges (e.g. repo on a dead mount).
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: String(text.prefix(maxOutput)))
            }
        }
    }
}

// MARK: - Engine

/// Generates ticket suggestions for a project via OpenRouter. Prefers real
/// ticket files in the repo (`tickets/` or `.palmo/tickets/` markdown);
/// otherwise derives suggestions from git history, status, diff, and TODOs.
@MainActor
final class TicketEngine: ObservableObject {
    @Published private(set) var tickets: [Ticket] = []
    @Published private(set) var isGenerating = false
    @Published private(set) var lastError: String?

    private let client = OpenRouterClient()
    private var task: Task<Void, Never>?
    /// Per-project cache: results keyed by cwd, valid for the same HEAD and TTL.
    private var cache: [String: (head: String?, at: Date, tickets: [Ticket])] = [:]
    private let cacheTTL: TimeInterval = 10 * 60

    /// Where ticket files may live inside a repo, in priority order.
    static let ticketDirNames = ["tickets", ".palmo/tickets"]

    func start(project: Project) {
        cancel()
        lastError = nil
        let head = ProjectRegistry.currentHead(cwd: project.cwd)
        if let hit = cache[project.cwd], hit.head == head,
           Date().timeIntervalSince(hit.at) < cacheTTL, !hit.tickets.isEmpty {
            tickets = hit.tickets
            return
        }
        tickets = []
        isGenerating = true
        task = Task { [weak self] in await self?.run(project: project, head: head) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isGenerating = false
    }

    func clear() {
        cancel()
        tickets = []
        lastError = nil
    }

    private func run(project: Project, head: String?) async {
        defer { isGenerating = false }
        let settings = AppSettings.shared
        let key = settings.openRouterKey
        let model = settings.openRouterModel
        guard !key.isEmpty else {
            lastError = OpenRouterClient.ClientError.noKey.localizedDescription
            return
        }

        let (system, user) = await Self.buildPrompt(cwd: project.cwd, name: project.name)
        if Task.isCancelled { return }

        var content: String?
        do {
            content = try await client.complete(system: system, user: user,
                                                model: model, apiKey: key)
        } catch {
            if Task.isCancelled { return }
            lastError = error.localizedDescription
            return
        }
        if Task.isCancelled { return }

        var parsed = Self.parseTickets(from: content ?? "", projectCwd: project.cwd)
        if parsed.isEmpty {
            // One retry, insisting on bare JSON.
            do {
                let retry = try await client.complete(
                    system: system,
                    user: user + "\n\nReply with ONLY the JSON object, no other text.",
                    model: model, apiKey: key)
                parsed = Self.parseTickets(from: retry, projectCwd: project.cwd)
            } catch { /* fall through to error below */ }
        }
        if Task.isCancelled { return }
        if parsed.isEmpty {
            lastError = "Couldn't parse ticket suggestions from the model."
            return
        }
        tickets = parsed
        cache[project.cwd] = (head: head, at: Date(), tickets: parsed)
    }

    // MARK: Context gathering + prompting

    /// Builds the system+user prompt from repo state (runs git off-main).
    nonisolated static func buildPrompt(cwd: String, name: String) async -> (system: String, user: String) {
        var parts: [String] = ["Project: \(name) (\(cwd))"]

        if let ticketFiles = readTicketFiles(cwd: cwd), !ticketFiles.isEmpty {
            parts.append("""
            The repo has a ticket backlog. Pick the 3-5 most valuable tickets to \
            work on next, ranked. Base titles/descriptions on these files:

            \(ticketFiles)
            """)
        } else {
            async let log = GitRunner.run(cwd: cwd, args: ["log", "--oneline", "-15"])
            async let status = GitRunner.run(cwd: cwd, args: ["status", "--porcelain"])
            async let diff = GitRunner.run(cwd: cwd, args: ["diff", "--no-color", "--stat"])
            let (l, s, d) = await (log, status, diff)
            if !l.isEmpty { parts.append("Recent commits:\n\(l)") }
            if !s.isEmpty { parts.append("Working tree status:\n\(s)") }
            if !d.isEmpty { parts.append("Uncommitted change summary:\n\(d)") }
            let todos = await GitRunner.run(
                cwd: cwd, args: ["grep", "-n", "-I", "-e", "TODO", "-e", "FIXME"],
                maxOutput: 2000)
            if !todos.isEmpty { parts.append("TODO/FIXME markers:\n\(todos)") }
            parts.append("""
            Based on this repo state, propose 3-5 concrete next tickets — bug \
            fixes, follow-ups implied by recent commits, unfinished work in the \
            tree, or TODOs worth clearing.
            """)
        }

        let system = """
        You suggest development tickets for a software project. Respond with \
        ONLY a JSON object of the shape \
        {"tickets":[{"title":"...","description":"...","prompt":"...","priority":1}]}. \
        "title" is at most 8 words. "description" is one or two sentences. \
        "prompt" is a complete, self-contained instruction to give Claude Code \
        (an AI coding agent working inside the repo) to do the work. "priority" \
        is 1 (do first) to 3. Suggest at most 5 tickets. No markdown, no prose.
        """
        return (system, parts.joined(separator: "\n\n"))
    }

    /// Reads ticket markdown files from the repo, if any (capped).
    nonisolated private static func readTicketFiles(cwd: String) -> String? {
        let fm = FileManager.default
        for dirName in ticketDirNames {
            let dir = URL(fileURLWithPath: cwd).appendingPathComponent(dirName)
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            let mds = files.filter { $0.pathExtension.lowercased() == "md" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .prefix(20)
            guard !mds.isEmpty else { continue }
            var out: [String] = []
            for url in mds {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                out.append("--- \(url.lastPathComponent) ---\n\(text.prefix(2000))")
            }
            if !out.isEmpty { return out.joined(separator: "\n\n") }
        }
        return nil
    }

    // MARK: Parsing

    /// Parses the model's JSON into tickets. Lenient about types; strict about
    /// requiring title + prompt. Clamps count and prompt sizes.
    nonisolated static func parseTickets(from content: String, projectCwd: String) -> [Ticket] {
        let cleaned = OpenRouterClient.stripFences(content)
        guard let data = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["tickets"] as? [[String: Any]]
        else { return [] }
        var out: [Ticket] = []
        for row in rows.prefix(5) {
            guard let title = (row["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
            else { continue }
            let prompt = (row["prompt"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !prompt.isEmpty else { continue }
            let priority: Int
            if let p = row["priority"] as? Int { priority = min(max(p, 1), 3) }
            else if let p = row["priority"] as? Double { priority = min(max(Int(p), 1), 3) }
            else { priority = 2 }
            out.append(Ticket(title: String(title.prefix(80)),
                              detail: String(((row["description"] as? String) ?? "").prefix(300)),
                              prompt: String(prompt.prefix(4000)),
                              priority: priority,
                              projectCwd: projectCwd))
        }
        return out.sorted { $0.priority < $1.priority }
    }
}
