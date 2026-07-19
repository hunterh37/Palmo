import XCTest

/// Air-command hold/cooldown behavior. Commands are remapped to `.askPalmo`
/// (which only posts an in-app notification) so tests never take real
/// screenshots or hit media keys.
@MainActor
final class GestureCommandEngineTests: XCTestCase {
    private var engine: GestureCommandEngine!
    private var now: CFTimeInterval = 100
    private var savedPeace: AirCommand!
    private var savedThumbs: AirCommand!
    private var fired: [(AirCommand, String)] = []

    override func setUp() {
        super.setUp()
        savedPeace = AppSettings.shared.peaceCommand
        savedThumbs = AppSettings.shared.thumbsUpCommand
        AppSettings.shared.peaceCommand = .askPalmo
        AppSettings.shared.thumbsUpCommand = .askPalmo
        engine = GestureCommandEngine()
        fired = []
        engine.onFired = { [weak self] cmd, label in self?.fired.append((cmd, label)) }
        now = 100
    }

    override func tearDown() {
        AppSettings.shared.peaceCommand = savedPeace
        AppSettings.shared.thumbsUpCommand = savedThumbs
        super.tearDown()
    }

    private func step(_ hand: DetectedHand?, seconds: CFTimeInterval) {
        let dt: CFTimeInterval = 1.0 / 30.0
        var t: CFTimeInterval = 0
        while t < seconds {
            now += dt
            engine.update(hand: hand, now: now)
            t += dt
        }
    }

    func testHeldPeaceSignFiresAfterHoldTime() {
        step(TestHands.peaceSign(), seconds: 0.3)
        XCTAssertTrue(fired.isEmpty, "must not fire before the 0.6s hold")
        XCTAssertGreaterThan(engine.holdProgress, 0.2)
        XCTAssertNotNil(engine.holdingLabel)
        step(TestHands.peaceSign(), seconds: 0.5)
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired.first?.0, .askPalmo)
    }

    func testBriefPeaceSignDoesNotFire() {
        step(TestHands.peaceSign(), seconds: 0.3)
        step(nil, seconds: 0.5)
        step(TestHands.peaceSign(), seconds: 0.3)
        XCTAssertTrue(fired.isEmpty, "interrupted holds must not accumulate")
    }

    func testCooldownBlocksImmediateRefire() {
        step(TestHands.peaceSign(), seconds: 1.0)
        XCTAssertEqual(fired.count, 1)
        // Keep holding straight through — cooldown (2.5s) blocks a second fire.
        step(TestHands.peaceSign(), seconds: 2.0)
        XCTAssertEqual(fired.count, 1)
        // After the cooldown, a fresh hold fires again.
        step(nil, seconds: 1.0)
        step(TestHands.peaceSign(), seconds: 1.0)
        XCTAssertEqual(fired.count, 2)
    }

    func testThumbsUpFiresItsOwnCommand() {
        step(TestHands.thumbsUp(), seconds: 1.0)
        XCTAssertEqual(fired.count, 1)
        XCTAssertTrue(fired.first?.1.contains("👍") == true)
    }

    func testGestureMappedToNoneNeverTracksOrFires() {
        AppSettings.shared.peaceCommand = AirCommand.none
        step(TestHands.peaceSign(), seconds: 2.0)
        XCTAssertTrue(fired.isEmpty)
        XCTAssertEqual(engine.holdProgress, 0)
    }

    func testOpenPalmIsNotACommandGesture() {
        step(TestHands.openPalm(), seconds: 2.0)
        XCTAssertTrue(fired.isEmpty)
        XCTAssertEqual(engine.holdProgress, 0)
    }
}
