import XCTest

final class PulseStateTests: XCTestCase {

    private func facts(head: String? = "abc123",
                       commits: [String] = ["Add feature"],
                       dirty: Int = 0,
                       live: Bool = false,
                       done: Bool = false,
                       canSend: Bool = false,
                       cwd: String = "/tmp/proj",
                       name: String = "proj") -> ProjectFacts {
        ProjectFacts(cwd: cwd, name: name, head: head, recentCommits: commits,
                     dirtyCount: dirty, hasLiveSession: live, sessionDone: done,
                     sessionLastMessage: "", canSend: canSend,
                     updatedAt: Date(timeIntervalSince1970: 1_000))
    }

    // MARK: - Deterministic state derivation

    func testRunningSessionIsWorking() {
        XCTAssertEqual(PulseFactsBuilder.state(from: facts(live: true, done: false)), .working)
    }

    func testFinishedSessionNeedsYou() {
        XCTAssertEqual(PulseFactsBuilder.state(from: facts(live: true, done: true)), .needsYou)
    }

    func testDirtyNoSessionIsBlocked() {
        XCTAssertEqual(PulseFactsBuilder.state(from: facts(dirty: 3, live: false)), .blocked)
    }

    func testCleanWithCommitsIsDone() {
        XCTAssertEqual(PulseFactsBuilder.state(from: facts(commits: ["x"], dirty: 0, live: false)), .done)
    }

    func testNothingNotableIsIdle() {
        XCTAssertEqual(PulseFactsBuilder.state(from: facts(head: nil, commits: [], dirty: 0, live: false)), .idle)
    }

    func testLiveSessionWinsOverDirtyTree() {
        // A running session takes precedence over uncommitted changes.
        XCTAssertEqual(PulseFactsBuilder.state(from: facts(dirty: 5, live: true, done: false)), .working)
    }

    // MARK: - Sort order

    func testSortRankOrdersMostUrgentFirst() {
        let ordered = PulseState.allCases.sorted { $0.sortRank < $1.sortRank }
        XCTAssertEqual(ordered, [.needsYou, .blocked, .working, .done, .idle])
    }

    // MARK: - Template narration

    func testTemplateNarrationBlockedCountsFiles() {
        let one = PulseFactsBuilder.templateNarration(for: facts(dirty: 1, live: false))
        XCTAssertTrue(one.detail.contains("1 file"))
        let many = PulseFactsBuilder.templateNarration(for: facts(dirty: 4, live: false))
        XCTAssertTrue(many.detail.contains("4 files"))
    }

    func testTemplateNarrationDoneMentionsCommit() {
        let n = PulseFactsBuilder.templateNarration(for: facts(commits: ["Ship it"], live: false))
        XCTAssertTrue(n.detail.contains("Ship it"))
    }

    // MARK: - Pulse merge + clamping

    func testPulseClampsLongHeadlineToSixWords() {
        let f = facts()
        let long = ProjectNarration(headline: "one two three four five six seven eight",
                                    detail: "d")
        let pulse = PulseFactsBuilder.pulse(from: f, narration: long)
        XCTAssertEqual(pulse.headline.split(separator: " ").count, 6)
    }

    func testPulseFallsBackToNameWhenHeadlineEmpty() {
        let f = facts(name: "myapp")
        let pulse = PulseFactsBuilder.pulse(from: f, narration: ProjectNarration(headline: "  ", detail: "d"))
        XCTAssertEqual(pulse.headline, "myapp")
    }

    func testPulseIdIsCwd() {
        let pulse = PulseFactsBuilder.pulse(from: facts(cwd: "/tmp/x"))
        XCTAssertEqual(pulse.id, "/tmp/x")
    }

    // MARK: - Cache key

    func testCacheKeyChangesWithHead() {
        let a = PulseFactsBuilder.cacheKey(for: facts(head: "aaa"))
        let b = PulseFactsBuilder.cacheKey(for: facts(head: "bbb"))
        XCTAssertNotEqual(a, b)
    }

    func testCacheKeyStableForSameState() {
        // updatedAt is intentionally NOT part of the key — only narratable state.
        var f1 = facts()
        f1.updatedAt = Date(timeIntervalSince1970: 1)
        var f2 = facts()
        f2.updatedAt = Date(timeIntervalSince1970: 999_999)
        XCTAssertEqual(PulseFactsBuilder.cacheKey(for: f1), PulseFactsBuilder.cacheKey(for: f2))
    }

    func testCacheKeyChangesWhenSessionFinishes() {
        let running = PulseFactsBuilder.cacheKey(for: facts(live: true, done: false))
        let finished = PulseFactsBuilder.cacheKey(for: facts(live: true, done: true))
        XCTAssertNotEqual(running, finished)
    }
}
