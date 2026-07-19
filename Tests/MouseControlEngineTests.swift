import XCTest

/// Mouse-orb interaction logic. Sensitivity is zeroed and click/scroll
/// gestures disabled so no real cursor movement, clicks, or scrolls are
/// posted even on a machine where the test runner has Accessibility trust.
@MainActor
final class MouseControlEngineTests: XCTestCase {
    private var engine: MouseControlEngine!
    private var now: CFTimeInterval = 100

    override func setUp() {
        super.setUp()
        engine = MouseControlEngine()
        engine.sensitivity = 0
        engine.pinchClickEnabled = false
        engine.scrollGestureEnabled = false
        now = 100
    }

    private func step(_ hand: DetectedHand?, seconds: CFTimeInterval) {
        let dt: CFTimeInterval = 1.0 / 30.0
        var t: CFTimeInterval = 0
        while t < seconds {
            now += dt
            engine.update(hand: hand, videoSize: TestHands.squareVideo, now: now)
            t += dt
        }
    }

    /// With a square frame the resting orb sits dead center.
    private let rest = CGPoint(x: 0.5, y: 0.5)

    func testDisabledEngineProducesNoOrb() {
        step(TestHands.openPalm(), seconds: 0.5)
        XCTAssertNil(engine.orb)
    }

    func testEnablingShowsOrbAtRestCenter() throws {
        engine.setEnabled(true, now: now)
        // The orb springs from the pre-enable default aspect's rest point to
        // the square frame's center; give the easing time to converge.
        step(nil, seconds: 2.0)
        let orb = try XCTUnwrap(engine.orb)
        XCTAssertEqual(orb.center.x, rest.x, accuracy: 0.02)
        XCTAssertEqual(orb.center.y, rest.y, accuracy: 0.02)
        XCTAssertFalse(orb.grabbed)
        XCTAssertEqual(orb.scale, 1.0, accuracy: 0.01, "pop-in should settle at 1")
    }

    func testDisablingRemovesOrb() {
        engine.setEnabled(true, now: now)
        step(nil, seconds: 0.2)
        engine.setEnabled(false, now: now)
        XCTAssertNil(engine.orb)
    }

    func testPinchOnOrbGrabsIt() throws {
        engine.setEnabled(true, now: now)
        step(nil, seconds: 0.5)
        step(TestHands.pinching(at: rest), seconds: 0.2)
        XCTAssertTrue(try XCTUnwrap(engine.orb).grabbed)
    }

    func testPinchFarFromOrbDoesNotGrab() throws {
        engine.setEnabled(true, now: now)
        step(nil, seconds: 0.5)
        step(TestHands.pinching(at: CGPoint(x: 0.1, y: 0.1)), seconds: 0.3)
        XCTAssertFalse(try XCTUnwrap(engine.orb).grabbed)
    }

    func testDraggedOrbFollowsPinchThenSpringsBack() throws {
        engine.setEnabled(true, now: now)
        step(nil, seconds: 0.5)
        step(TestHands.pinching(at: rest), seconds: 0.2)
        // Drag toward the upper-left.
        step(TestHands.pinching(at: CGPoint(x: 0.25, y: 0.25)), seconds: 0.5)
        var orb = try XCTUnwrap(engine.orb)
        XCTAssertTrue(orb.grabbed)
        XCTAssertEqual(orb.center.x, 0.25, accuracy: 0.03)
        XCTAssertEqual(orb.center.y, 0.25, accuracy: 0.03)
        // Release: the orb springs back to rest.
        step(TestHands.openPalm(), seconds: 1.5)
        orb = try XCTUnwrap(engine.orb)
        XCTAssertFalse(orb.grabbed)
        XCTAssertEqual(orb.center.x, rest.x, accuracy: 0.03)
        XCTAssertEqual(orb.center.y, rest.y, accuracy: 0.03)
    }

    func testHandAlreadyPinchingWhenSeenDoesNotGrab() throws {
        engine.setEnabled(true, now: now)
        // First frame arrives mid-pinch away from the orb, slides onto it
        // while still pinching: must not grab (requires a fresh pinch).
        step(TestHands.pinching(at: CGPoint(x: 0.1, y: 0.5)), seconds: 0.2)
        step(TestHands.pinching(at: rest), seconds: 0.3)
        XCTAssertFalse(try XCTUnwrap(engine.orb).grabbed)
    }
}
