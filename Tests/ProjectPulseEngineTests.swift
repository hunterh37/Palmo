import XCTest

/// A narrator that records how many projects it was asked about, so tests can
/// assert the engine only narrates changed projects.
final class CountingNarrator: PulseNarrator, @unchecked Sendable {
    private(set) var narratedCwds: [[String]] = []
    func narrate(_ facts: [ProjectFacts]) async -> [String: ProjectNarration] {
        narratedCwds.append(facts.map(\.cwd))
        var out: [String: ProjectNarration] = [:]
        for f in facts { out[f.cwd] = ProjectNarration(headline: "H-\(f.name)", detail: "D") }
        return out
    }
}

@MainActor
final class ProjectPulseEngineTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-\(UUID().uuidString).json")
    }

    func testGatherFactsMapsSessionToCwd() async {
        let projects = [Project(cwd: "/tmp/a", lastActivity: Date(), lastSeenHead: nil)]
        let sessions = [ClaudeSession(id: "s1", cwd: "/tmp/a", isDone: true,
                                      updatedAt: Date(), lastMessage: "hi", port: 9000)]
        let facts = await ProjectPulseEngine.gatherFacts(projects: projects, sessions: sessions)
        XCTAssertEqual(facts.count, 1)
        XCTAssertTrue(facts[0].hasLiveSession)
        XCTAssertTrue(facts[0].sessionDone)
        XCTAssertTrue(facts[0].canSend)
    }

    func testGatherFactsNoSessionMeansNoLiveSession() async {
        let projects = [Project(cwd: "/tmp/lonely", lastActivity: Date(), lastSeenHead: nil)]
        let facts = await ProjectPulseEngine.gatherFacts(projects: projects, sessions: [])
        XCTAssertFalse(facts[0].hasLiveSession)
    }

    func testPersistenceRoundTrips() throws {
        let url = tempURL()
        let engine = ProjectPulseEngine(fileURL: url)
        let pulse = PulseFactsBuilder.pulse(from:
            ProjectFacts(cwd: "/tmp/p", name: "p", head: "h", recentCommits: ["c"],
                         dirtyCount: 0, hasLiveSession: false, sessionDone: false,
                         sessionLastMessage: "", canSend: false, updatedAt: Date()))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode([pulse]).write(to: url, options: .atomic)

        let reloaded = ProjectPulseEngine(fileURL: url)
        XCTAssertEqual(reloaded.pulses.map(\.cwd), ["/tmp/p"])
        try? FileManager.default.removeItem(at: url)
    }
}
