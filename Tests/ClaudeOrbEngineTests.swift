import XCTest

/// Collapsed-mode Claude session orbs: fist-raise, point-to-select,
/// composing, reply selection, and the timeouts in between — the whole
/// "reply to a Claude session with your hand" flow minus the on-device model.
@MainActor
final class ClaudeOrbEngineTests: XCTestCase {
    private var engine: ClaudeOrbEngine!
    private var now: CFTimeInterval = 100

    private let session = ClaudeSession(
        id: "s1", cwd: "/tmp/proj", isDone: true, updatedAt: .now,
        lastMessage: "Tests pass. Ship it?", port: 4242)

    private let presets = [
        ReplyPreset(text: "Yes, go ahead", tier: .quick),
        ReplyPreset(text: "Run the linter first", tier: .quick),
    ]

    override func setUp() {
        super.setUp()
        engine = ClaudeOrbEngine()
        now = 100
    }

    private func step(_ hand: DetectedHand?, seconds: CFTimeInterval,
                      sessions: [ClaudeSession]? = nil,
                      presets: [ReplyPreset] = []) {
        let dt: CFTimeInterval = 1.0 / 30.0
        var t: CFTimeInterval = 0
        while t < seconds {
            now += dt
            engine.update(sessions: sessions ?? [session], presets: presets,
                          hand: hand, videoSize: TestHands.squareVideo, now: now)
            t += dt
        }
    }

    /// Raised orb row for a single session sits centered near the top.
    private let raisedOrbCenter = CGPoint(x: 0.5, y: 0.16)

    // MARK: Docked / raise

    func testNoSessionsShowsNothing() {
        step(TestHands.fist(), seconds: 2, sessions: [])
        XCTAssertTrue(engine.orbs.isEmpty)
        XCTAssertEqual(engine.fistProgress, 0)
    }

    func testOrbsStartDockedAtBottom() {
        step(nil, seconds: 0.2)
        XCTAssertEqual(engine.orbs.count, 1)
        XCTAssertGreaterThan(engine.orbs[0].center.y, 0.8, "docked orbs sit low")
        XCTAssertTrue(engine.orbs[0].isDone)
    }

    func testFistHoldRaisesOrbs() {
        step(TestHands.fist(), seconds: 0.5)
        XCTAssertGreaterThan(engine.fistProgress, 0.3)
        step(TestHands.fist(), seconds: 0.7)  // completes the 1s hold
        step(nil, seconds: 0.8)               // raise animation (0.5s)
        XCTAssertLessThan(engine.orbs[0].center.y, 0.2, "raised orbs sit high")
    }

    func testReleasingFistEarlyCancelsRaise() {
        step(TestHands.fist(), seconds: 0.5)
        step(nil, seconds: 0.2)
        step(TestHands.fist(), seconds: 0.5)
        // Two half-holds must not add up to one full hold.
        XCTAssertGreaterThan(engine.orbs[0].center.y, 0.8)
    }

    // MARK: Select → compose → reply (full e2e)

    private func raise() {
        step(TestHands.fist(), seconds: 1.2)
        step(nil, seconds: 0.8)
    }

    func testFullFlow_RaisePointComposeReplySend() {
        raise()

        // Point at the session orb for 1s → composing starts.
        var sawSelection = false
        let point = TestHands.pointing(at: raisedOrbCenter)
        for _ in 0..<40 {
            now += 1.0 / 30.0
            engine.update(sessions: [session], presets: [], hand: point,
                          videoSize: TestHands.squareVideo, now: now)
            if engine.selectedSessionID == "s1" { sawSelection = true }
        }
        XCTAssertTrue(sawSelection, "session orb should be selected after a 1s dwell")
        XCTAssertEqual(engine.composingSessionID, "s1")

        // Session orbs give way to reply orbs while composing.
        step(nil, seconds: 0.2, presets: presets)
        XCTAssertTrue(engine.orbs.isEmpty)
        XCTAssertEqual(engine.replyOrbs.count, 2)

        // Point at the first reply orb for 1s → reply selected, orbs lower.
        let replyCenter = engine.replyOrbs[0].center
        var reply: (sessionID: String, text: String)?
        let pointReply = TestHands.pointing(at: replyCenter)
        for _ in 0..<40 {
            now += 1.0 / 30.0
            engine.update(sessions: [session], presets: presets, hand: pointReply,
                          videoSize: TestHands.squareVideo, now: now)
            if let r = engine.selectedReply { reply = r }
        }
        XCTAssertEqual(reply?.sessionID, "s1")
        XCTAssertEqual(reply?.text, "Yes, go ahead")
        XCTAssertNil(engine.composingSessionID)
    }

    func testFistWhileComposingCancelsBackDown() {
        raise()
        step(TestHands.pointing(at: raisedOrbCenter), seconds: 1.3)
        XCTAssertEqual(engine.composingSessionID, "s1")
        step(TestHands.fist(), seconds: 1.3, presets: presets)
        XCTAssertNil(engine.composingSessionID)
        XCTAssertTrue(engine.replyOrbs.isEmpty)
    }

    func testIdleTimeoutLowersRaisedOrbs() {
        raise()
        step(nil, seconds: 9)  // idle timeout is 8s
        step(nil, seconds: 0.8)
        XCTAssertGreaterThan(engine.orbs[0].center.y, 0.8, "orbs should re-dock")
    }

    func testComposingSessionVanishingBailsOut() {
        raise()
        step(TestHands.pointing(at: raisedOrbCenter), seconds: 1.3)
        XCTAssertEqual(engine.composingSessionID, "s1")
        let other = ClaudeSession(id: "s2", cwd: "/tmp/other", isDone: false,
                                  updatedAt: .now, lastMessage: "", port: nil)
        step(nil, seconds: 0.3, sessions: [other])
        XCTAssertNil(engine.composingSessionID)
    }

    func testPointingWhileDockedSelectsNothing() {
        step(TestHands.pointing(at: raisedOrbCenter), seconds: 2)
        XCTAssertNil(engine.selectedSessionID)
        XCTAssertNil(engine.composingSessionID)
    }
}
