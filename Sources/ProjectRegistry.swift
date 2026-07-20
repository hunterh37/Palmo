import Foundation

/// A project Palmo knows about: any working directory ever seen in a Claude
/// Code session. Persisted so projects survive the sessions that revealed them.
struct Project: Identifiable, Codable, Equatable {
    var id: String { cwd }
    /// Standardized absolute path of the project directory.
    var cwd: String
    var lastActivity: Date
    /// Resolved commit hash of the last observed .git/HEAD, for change detection.
    var lastSeenHead: String?

    var name: String {
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty ? "project" : last
    }
}

/// Persistent list of known projects, auto-fed from Claude session cwds.
@MainActor
final class ProjectRegistry: ObservableObject {
    @Published private(set) var projects: [Project] = []

    /// Injectable for tests; defaults to the app support dir.
    let fileURL: URL

    init(fileURL: URL = ClaudeSessionStore.supportDir.appendingPathComponent("projects.json")) {
        self.fileURL = fileURL
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Project].self, from: data)
        else { return }
        projects = decoded.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Register (or refresh) a project by working directory. Ignores empty or
    /// nonexistent paths. Returns the registered project, if any.
    @discardableResult
    func register(cwd: String) -> Project? {
        let path = (cwd as NSString).standardizingPath
        guard !path.isEmpty, path != "/" else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue else { return nil }

        if let i = projects.firstIndex(where: { $0.cwd == path }) {
            projects[i].lastActivity = Date()
            save()
            return projects[i]
        }
        let project = Project(cwd: path, lastActivity: Date(), lastSeenHead: nil)
        projects.append(project)
        projects.sort { $0.lastActivity > $1.lastActivity }
        save()
        return project
    }

    func remove(cwd: String) {
        projects.removeAll { $0.cwd == cwd }
        save()
    }

    func updateHead(cwd: String, head: String?) {
        guard let i = projects.firstIndex(where: { $0.cwd == cwd }) else { return }
        guard projects[i].lastSeenHead != head else { return }
        projects[i].lastSeenHead = head
        save()
    }

    /// Most recently active project, if any.
    var mostRecent: Project? { projects.max { $0.lastActivity < $1.lastActivity } }

    private func save() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(projects) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: Git HEAD (cheap change detection, pure file reads)

    /// Resolved commit hash for a repo's HEAD, or nil when not a git repo.
    /// Reads .git/HEAD and, if it points at a ref, that ref file — no
    /// subprocess, so it's cheap enough to poll.
    nonisolated static func currentHead(cwd: String) -> String? {
        let gitDir = URL(fileURLWithPath: cwd).appendingPathComponent(".git")
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"),
                                     encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        guard head.hasPrefix("ref: ") else { return head.isEmpty ? nil : head }
        let ref = String(head.dropFirst(5))
        if let hash = try? String(contentsOf: gitDir.appendingPathComponent(ref),
                                  encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !hash.isEmpty {
            return hash
        }
        // Packed refs fallback.
        if let packed = try? String(contentsOf: gitDir.appendingPathComponent("packed-refs"),
                                    encoding: .utf8) {
            for line in packed.split(separator: "\n") where line.hasSuffix(ref) {
                let hash = line.split(separator: " ").first.map(String.init)
                if let hash, hash.count >= 7 { return hash }
            }
        }
        return nil
    }
}
