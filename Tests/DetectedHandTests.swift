import XCTest

/// Gesture-derivation unit tests: the predicates every interaction in the
/// app hangs off. If these regress, everything downstream misfires.
final class DetectedHandTests: XCTestCase {

    // MARK: Open palm

    func testOpenPalmIsDetected() {
        let hand = TestHands.openPalm()
        XCTAssertEqual(hand.extendedFingerCount, 4)
        XCTAssertTrue(hand.isOpenPalmUp)
        XCTAssertFalse(hand.isFist)
        XCTAssertFalse(hand.isPeaceSign)
        XCTAssertFalse(hand.isThumbsUp)
    }

    // MARK: Fist

    func testFistIsDetected() {
        let hand = TestHands.fist()
        XCTAssertEqual(hand.extendedFingerCount, 0)
        XCTAssertTrue(hand.isFist)
        XCTAssertTrue(hand.hasAllFingerTips)
        XCTAssertFalse(hand.isOpenPalmUp)
    }

    /// A one-finger point must never read as a fist — a pointing user was
    /// accidentally dismissing the menu before this rule existed.
    func testIndexPointIsNotAFist() {
        let hand = TestHands.pointing(at: CGPoint(x: 0.5, y: 0.35))
        XCTAssertTrue(hand.isIndexExtended)
        XCTAssertFalse(hand.isFist)
    }

    /// Missing fingertips must not fake a fist (`hasAllFingerTips` guards this).
    func testMissingFingerTipsAreDetected() {
        var hand = TestHands.fist()
        hand.points[.ringTip] = nil
        XCTAssertFalse(hand.hasAllFingerTips)
    }

    // MARK: Peace sign / thumbs-up

    func testPeaceSignIsDetected() {
        let hand = TestHands.peaceSign()
        XCTAssertTrue(hand.isPeaceSign)
        XCTAssertFalse(hand.isFist)
        XCTAssertFalse(hand.isOpenPalmUp)
    }

    func testThumbsUpIsDetected() {
        let hand = TestHands.thumbsUp()
        XCTAssertTrue(hand.isThumbsUp)
        XCTAssertFalse(hand.isPeaceSign)
    }

    func testThumbBarelyRaisedIsNotThumbsUp() {
        var hand = TestHands.fist()
        // Above the knuckle but not > handSpan * 1.1 above the wrist.
        hand.points[.thumbKnuckle] = CGPoint(x: 0.5, y: 0.66)
        hand.points[.thumbTip] = CGPoint(x: 0.5, y: 0.62)
        XCTAssertFalse(hand.isThumbsUp)
    }

    // MARK: Geometry helpers

    func testPalmCenterAveragesWristAndKnuckles() throws {
        let hand = TestHands.openPalm(wrist: CGPoint(x: 0.5, y: 0.7))
        let palm = try XCTUnwrap(hand.palmCenter)
        // Wrist at 0.7, four knuckles at 0.55 → average 0.58.
        XCTAssertEqual(palm.y, 0.58, accuracy: 0.001)
        XCTAssertEqual(palm.x, 0.5, accuracy: 0.001)
    }

    func testPalmCenterNilWhenTooFewJoints() {
        var hand = TestHands.openPalm()
        hand.points = [.wrist: CGPoint(x: 0.5, y: 0.7),
                       .indexKnuckle: CGPoint(x: 0.5, y: 0.55)]
        XCTAssertNil(hand.palmCenter)
    }

    func testPinchPointIsThumbIndexMidpoint() throws {
        let hand = TestHands.pinching(at: CGPoint(x: 0.4, y: 0.3))
        let p = try XCTUnwrap(hand.pinchPoint)
        XCTAssertEqual(p.x, 0.4, accuracy: 0.001)
        XCTAssertEqual(p.y, 0.3, accuracy: 0.001)
        XCTAssertTrue(hand.isPinching)
    }
}
