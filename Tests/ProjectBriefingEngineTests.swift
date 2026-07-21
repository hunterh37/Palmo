import XCTest

/// Briefing state machine: summon → point-highlight → dwell-expand →
/// dwell-chip-fire → collapse / fist-dismiss / idle-timeout.
@MainActor
final class ProjectBriefingEngineTests: XCTestCase {
    private var engine: ProjectBriefingEngine!
    private var now: CFTimeInterval = 100
    private var pulses: [ProjectPulse] = []

    override func setUp() {
        super.setUp()
        engine = ProjectBriefingEngine()
        now = 100
        pulses = [
            pulse(cwd: "/a", name: "alpha", state: .needsYou, canSend: true, live: true),
            pulse(cwd: "/b", name: "bravo", state: .working, live: true),
            pulse(cwd: "/c", name: "charlie", state: .done),
        ]
    }

    private func pulse(cwd: String, name: String, state: PulseState,
                       canSend: Bool = false, live: Bool = false) -> ProjectPulse {
        ProjectPulse(cwd: cwd, name: name, state: state, headline: "H", detail: "D",
                     recentCommit: "c", isDirty: false, hasLiveSession: live,
                     canSend: canSend, updatedAt: Date(timeIntervalSince1970: 1))
    }

    private func step(_ hand: DetectedHand?, seconds: CFTimeInterval) {
        let dt: CFTimeInterval = 1.0 / 30.0
        var t: CFTimeInterval = 0
        while t < seconds {
            now += dt
            engine.update(pulses: pulses, hand: hand,
                          videoSize: TestHands.squareVideo, now: now)
            t += dt
        }
    }

    /// Drive until `firedAction` appears (it lives for one frame).
    private func stepUntilFired(_ hand: DetectedHand?, maxSeconds: CFTimeInterval) -> PulseAction? {
        let dt: CFTimeInterval = 1.0 / 30.0
        var t: CFTimeInterval = 0
        while t < maxSeconds {
            now += dt
            engine.update(pulses: pulses, hand: hand,
                          videoSize: TestHands.squareVideo, now: now)
            if let f = engine.firedAction { return f }
            t += dt
        }
        return nil
    }

    func testStartsHidden() {
        XCTAssertFalse(engine.isActive)
        XCTAssertTrue(engine.bubbles.isEmpty)
    }

    func testSummonByDwellOnAnchor() {
        step(TestHands.pointing(at: engine.anchor), seconds: 1.3)
        XCTAssertTrue(engine.isActive)
        XCTAssertEqual(engine.bubbles.count, 3)
    }

    func testPointingAwayFromAnchorDoesNotSummon() {
        step(TestHands.pointing(at: CGPoint(x: 0.9, y: 0.2)), seconds: 1.3)
        XCTAssertFalse(engine.isActive)
    }

    func testBeginOpensDirectly() {
        engine.begin(now: now)
        step(nil, seconds: 0.1)
        XCTAssertTrue(engine.isActive)
        XCTAssertEqual(engine.bubbles.count, 3)
        XCTAssertTrue(engine.bubbles.allSatisfy { !$0.expanded })
    }

    func testBubblesSortedAsProvided() {
        engine.begin(now: now)
        step(nil, seconds: 0.1)
        XCTAssertEqual(engine.bubbles.map(\.id), ["/a", "/b", "/c"])
    }

    func testDwellOnBubbleExpandsIt() throws {
        engine.begin(now: now)
        step(nil, seconds: 0.1)
        let target = try XCTUnwrap(engine.bubbles.first)  // /a at top
        step(TestHands.pointing(at: target.center), seconds: 1.2)
        XCTAssertEqual(engine.expandedID, "/a")
        XCTAssertTrue(engine.bubbles.first?.expanded ?? false)
        XCTAssertFalse(engine.actionChips.isEmpty)
    }

    func testExpandedNeedsYouOffersReplyChip() throws {
        engine.begin(now: now)
        step(nil, seconds: 0.1)
        let target = try XCTUnwrap(engine.bubbles.first)  // /a: needsYou + canSend
        step(TestHands.pointing(at: target.center), seconds: 1.2)
        XCTAssertTrue(engine.actionChips.contains { $0.action == .reply(cwd: "/a") })
    }

    func testDwellOnReplyChipFiresAction() throws {
        engine.begin(now: now)
        step(nil, seconds: 0.1)
        let bubble = try XCTUnwrap(engine.bubbles.first)
        step(TestHands.pointing(at: bubble.center), seconds: 1.2)
        let chip = try XCTUnwrap(engine.actionChips.first { $0.action == .reply(cwd: "/a") })
        let fired = stepUntilFired(TestHands.pointing(at: chip.center), maxSeconds: 1.5)
        XCTAssertEqual(fired, .reply(cwd: "/a"))
    }

    func testDoneProjectHasNoReplyChip() throws {
        engine.begin(now: now)
        step(nil, seconds: 0.1)
        let charlie = try XCTUnwrap(engine.bubbles.first { $0.id == "/c" })
        step(TestHands.pointing(at: charlie.center), seconds: 1.2)
        XCTAssertEqual(engine.expandedID, "/c")
        XCTAssertFalse(engine.actionChips.contains { $0.action == .reply(cwd: "/c") })
    }

    func testFistHoldDismisses() {
        engine.begin(now: now)
        step(nil, seconds: 0.1)
        step(TestHands.fist(), seconds: 1.2)
        XCTAssertFalse(engine.isActive)
        XCTAssertTrue(engine.bubbles.isEmpty)
    }

    func testIdleTimeoutDismisses() {
        engine.begin(now: now)
        step(nil, seconds: 13)
        XCTAssertFalse(engine.isActive)
    }

    func testEmptyPulsesResets() {
        engine.begin(now: now)
        step(nil, seconds: 0.1)
        XCTAssertTrue(engine.isActive)
        pulses = []
        step(nil, seconds: 0.1)
        XCTAssertFalse(engine.isActive)
    }

    func testActionsHelperCapsAtFour() {
        let p = pulse(cwd: "/x", name: "x", state: .needsYou, canSend: true, live: true)
        XCTAssertLessThanOrEqual(PulseAction.actions(for: p).count, 4)
    }
}
