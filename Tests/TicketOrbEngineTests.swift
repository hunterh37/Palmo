import XCTest

/// Ticket-card interaction state machine: announce → load → present →
/// pinch-grab → drop-zone send / spring-back / fist dismiss.
@MainActor
final class TicketOrbEngineTests: XCTestCase {
    private var engine: TicketOrbEngine!
    private var now: CFTimeInterval = 100
    private var tickets: [Ticket] = []

    override func setUp() {
        super.setUp()
        engine = TicketOrbEngine()
        now = 100
        tickets = [
            Ticket(title: "A", detail: "", prompt: "do a", priority: 1, projectCwd: "/p"),
            Ticket(title: "B", detail: "", prompt: "do b", priority: 2, projectCwd: "/p"),
            Ticket(title: "C", detail: "", prompt: "do c", priority: 3, projectCwd: "/p"),
        ]
    }

    /// Steps frames at 30fps with a constant hand + ticket feed.
    private func step(_ hand: DetectedHand?, seconds: CFTimeInterval,
                      tickets: [Ticket]? = nil, generating: Bool = false) {
        let dt: CFTimeInterval = 1.0 / 30.0
        var t: CFTimeInterval = 0
        while t < seconds {
            now += dt
            engine.update(tickets: tickets ?? self.tickets, generating: generating,
                          hand: hand, videoSize: TestHands.squareVideo, now: now)
            t += dt
        }
    }

    /// Runs the announce beat and delivers tickets so cards are presenting.
    private func present() {
        engine.begin(now: now)
        step(nil, seconds: 1.2)  // announce (0.9s) → loading → adopt tickets
        XCTAssertFalse(engine.orbs.isEmpty, "cards should be presenting")
    }

    func testIdleEngineIgnoresUpdates() {
        step(TestHands.openPalm(), seconds: 0.5)
        XCTAssertTrue(engine.orbs.isEmpty)
        XCTAssertFalse(engine.isActive)
    }

    func testAnnounceThenLoadingThenPresenting() {
        engine.begin(now: now)
        XCTAssertTrue(engine.isAnnouncing)
        step(nil, seconds: 0.5, tickets: [], generating: true)
        XCTAssertTrue(engine.isAnnouncing)
        step(nil, seconds: 0.6, tickets: [], generating: true)
        XCTAssertTrue(engine.isLoading)
        step(nil, seconds: 0.2)  // tickets arrive
        XCTAssertEqual(engine.orbs.count, 3)
    }

    func testGenerationEndingEmptyResetsEngine() {
        engine.begin(now: now)
        step(nil, seconds: 1.2, tickets: [], generating: true)
        XCTAssertTrue(engine.isLoading)
        step(nil, seconds: 0.2, tickets: [], generating: false)
        XCTAssertFalse(engine.isActive)
    }

    func testPinchOnCardGrabsIt() throws {
        present()
        let target = try XCTUnwrap(engine.orbs.first)
        step(TestHands.pinching(at: target.center), seconds: 0.2)
        let grabbed = try XCTUnwrap(engine.orbs.first(where: \.grabbed))
        XCTAssertEqual(grabbed.id, target.id)
    }

    func testPinchFarFromCardsDoesNotGrab() {
        present()
        step(TestHands.pinching(at: CGPoint(x: 0.5, y: 0.95)), seconds: 0.3)
        XCTAssertNil(engine.orbs.first(where: \.grabbed))
    }

    func testReleaseOutsideZoneSpringsBack() throws {
        present()
        let target = try XCTUnwrap(engine.orbs.first)
        step(TestHands.pinching(at: target.center), seconds: 0.2)
        // Drag off to the side, then release.
        step(TestHands.pinching(at: CGPoint(x: 0.15, y: 0.5)), seconds: 0.5)
        step(TestHands.openPalm(), seconds: 0.5)
        XCTAssertNil(engine.firedTicket)
        XCTAssertEqual(engine.orbs.count, 3, "no ticket should be consumed")
        XCTAssertNil(engine.orbs.first(where: \.grabbed))
    }

    func testDragToDropZoneAndReleaseFires() throws {
        present()
        let target = try XCTUnwrap(engine.orbs.first)
        step(TestHands.pinching(at: target.center), seconds: 0.2)
        // Carry into the drop zone (smoothing needs a few frames to arrive).
        step(TestHands.pinching(at: engine.dropZoneCenter), seconds: 0.3)
        // Release inside: capture the one-frame fired flag.
        var fired: Ticket?
        let dt: CFTimeInterval = 1.0 / 30.0
        for _ in 0..<10 {
            now += dt
            engine.update(tickets: tickets, generating: false,
                          hand: TestHands.openPalm(),
                          videoSize: TestHands.squareVideo, now: now)
            if let f = engine.firedTicket { fired = f; break }
        }
        XCTAssertEqual(fired?.id, target.id)
    }

    func testHoldInDropZoneFiresAfterDwell() throws {
        present()
        let target = try XCTUnwrap(engine.orbs.first)
        step(TestHands.pinching(at: target.center), seconds: 0.2)
        var fired: Ticket?
        let dt: CFTimeInterval = 1.0 / 30.0
        for _ in 0..<60 {  // up to 2s of holding in the zone
            now += dt
            engine.update(tickets: tickets, generating: false,
                          hand: TestHands.pinching(at: engine.dropZoneCenter),
                          videoSize: TestHands.squareVideo, now: now)
            if let f = engine.firedTicket { fired = f; break }
        }
        XCTAssertEqual(fired?.id, target.id)
    }

    func testFistHoldDismisses() {
        present()
        step(TestHands.fist(), seconds: 1.0)
        XCTAssertFalse(engine.isActive)
        XCTAssertTrue(engine.orbs.isEmpty)
    }

    func testIdleTimeoutDismisses() {
        present()
        step(nil, seconds: 21)
        XCTAssertFalse(engine.isActive)
    }

    func testResetClearsEverything() {
        present()
        engine.reset()
        XCTAssertFalse(engine.isActive)
        XCTAssertTrue(engine.orbs.isEmpty)
        XCTAssertNil(engine.firedTicket)
    }
}
