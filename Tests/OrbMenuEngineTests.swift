import XCTest

/// State-machine tests for the main orb menu, driven end-to-end by synthetic
/// hands and a fake clock — the same call pattern `HandMenuModel.publish`
/// uses per frame.
final class OrbMenuEngineTests: XCTestCase {
    private var engine: OrbMenuEngine!
    private var now: CFTimeInterval = 100

    /// The assistant action posts a notification instead of launching a real
    /// app, which keeps the full selection e2e safe to run.
    private let assistantAction = MenuAction(
        id: "assistant", name: "Ask Palmo", kind: .assistant,
        color: (0.75, 0.55, 1.00))

    override func setUp() {
        super.setUp()
        engine = OrbMenuEngine()
        engine.actions = [assistantAction]
        now = 100
    }

    /// Advance the engine `seconds` in 30 fps steps with a constant hand.
    private func step(_ hand: DetectedHand?, seconds: CFTimeInterval) {
        let dt: CFTimeInterval = 1.0 / 30.0
        var t: CFTimeInterval = 0
        while t < seconds {
            now += dt
            engine.setHover(from: hand)
            engine.update(hand: hand, videoSize: TestHands.squareVideo, now: now)
            t += dt
        }
    }

    private var isOpen: Bool {
        if case .open = engine.state { return true }
        return false
    }

    private var isHidden: Bool {
        if case .hidden = engine.state { return true }
        return false
    }

    // MARK: Summoning

    func testMenuStaysHiddenWithoutHand() {
        step(nil, seconds: 3)
        XCTAssertTrue(isHidden)
        XCTAssertTrue(engine.orbs.isEmpty)
    }

    func testTouchingAvatarForOneSecondSummonsMenu() {
        let touch = TestHands.pointing(at: engine.avatarCenter)
        step(touch, seconds: 0.5)
        XCTAssertTrue(isHidden)
        XCTAssertGreaterThan(engine.summonProgress, 0.3, "hold ring should be charging")
        step(touch, seconds: 0.7)   // past the 1s hold → summoning
        step(nil, seconds: 1.0)     // summon animation (0.75s) completes
        XCTAssertTrue(isOpen)
        XCTAssertFalse(engine.orbs.isEmpty)
    }

    func testTouchingAwayFromAvatarNeverSummons() {
        let far = TestHands.pointing(at: CGPoint(x: 0.85, y: 0.2))
        step(far, seconds: 3)
        XCTAssertTrue(isHidden)
        XCTAssertEqual(engine.summonProgress, 0)
    }

    func testLeavingAvatarResetsSummonHold() {
        let touch = TestHands.pointing(at: engine.avatarCenter)
        step(touch, seconds: 0.6)
        step(TestHands.pointing(at: CGPoint(x: 0.9, y: 0.1)), seconds: 0.2)
        // Coming back must restart the 1s hold, not resume it.
        step(touch, seconds: 0.6)
        XCTAssertTrue(isHidden)
    }

    // MARK: Selection (point + dwell)

    private func openMenu() {
        let touch = TestHands.pointing(at: engine.avatarCenter)
        step(touch, seconds: 1.2)
        step(nil, seconds: 1.0)
        XCTAssertTrue(isOpen)
    }

    /// With a single action, the orb fans out to 90° above the command
    /// center: anchor (avatar) minus hover offset minus fan radius.
    private var singleOrbCenter: CGPoint {
        CGPoint(x: engine.avatarCenter.x, y: engine.avatarCenter.y - 0.20 - 0.24)
    }

    func testFullFlow_SummonPointDwellFiresAction() {
        openMenu()
        let fired = expectation(forNotification: .openAssistant, object: nil)
        step(nil, seconds: 0.6)  // wait out the selection grace period
        step(TestHands.pointing(at: singleOrbCenter), seconds: 1.2)
        wait(for: [fired], timeout: 1)
        if case .launching(let action, _, _) = engine.state {
            XCTAssertEqual(action.id, "assistant")
        } else {
            XCTFail("expected launching state, got \(engine.state)")
        }
        // Launch animation ends back at hidden.
        step(nil, seconds: 0.8)
        XCTAssertTrue(isHidden)
    }

    func testSelectionBlockedDuringGracePeriod() {
        openMenu()
        // Dwell immediately (inside the 0.5s grace): must not fire.
        step(TestHands.pointing(at: singleOrbCenter), seconds: 0.3)
        XCTAssertNil(engine.firedAction)
        XCTAssertTrue(isOpen)
    }

    func testSlidingOffOrbCancelsDwell() {
        openMenu()
        step(nil, seconds: 0.6)
        step(TestHands.pointing(at: singleOrbCenter), seconds: 0.6)
        XCTAssertGreaterThan(engine.dwellProgress, 0.3)
        step(TestHands.pointing(at: CGPoint(x: 0.9, y: 0.9)), seconds: 0.2)
        XCTAssertEqual(engine.dwellProgress, 0)
        XCTAssertTrue(isOpen, "menu should stay open after a cancelled dwell")
    }

    // MARK: Dismissal

    func testFistHoldDismissesMenu() {
        openMenu()
        let fist = TestHands.fist()
        step(fist, seconds: 0.5)
        XCTAssertGreaterThan(engine.dismissProgress, 0.3)
        step(fist, seconds: 0.7)   // past the 1s hold → closing
        step(nil, seconds: 0.5)    // closing animation (0.25s)
        XCTAssertTrue(isHidden)
        XCTAssertTrue(engine.orbs.isEmpty)
    }

    func testFistWithMissingFingertipsDoesNotDismiss() {
        openMenu()
        var fist = TestHands.fist()
        fist.points[.middleTip] = nil  // partially tracked hand
        step(fist, seconds: 2)
        XCTAssertTrue(isOpen, "untracked fingertips must not fake a fist")
    }

    func testResetClearsEverything() {
        openMenu()
        engine.reset()
        XCTAssertTrue(isHidden)
        XCTAssertTrue(engine.orbs.isEmpty)
        XCTAssertEqual(engine.dismissProgress, 0)
        XCTAssertEqual(engine.summonProgress, 0)
    }

    // MARK: Layout

    func testOpenLayoutContainsCommandOrbPlusActions() {
        engine.actions = MenuAction.ring(bundleIDs: ["com.apple.Safari"])
        openMenu()
        step(nil, seconds: 1)  // let the fan settle
        XCTAssertEqual(engine.orbs.count, engine.actions.count + 1)
        XCTAssertTrue(engine.orbs.contains { $0.isCommand })
        for orb in engine.orbs where !orb.isCommand {
            XCTAssertNotNil(orb.action)
            XCTAssertTrue((0...1).contains(orb.center.x), "orb x in frame")
            XCTAssertTrue((0...1).contains(orb.center.y), "orb y in frame")
        }
    }
}
