import XCTest

final class TicketEngineTests: XCTestCase {
    private let cwd = "/tmp/fake-project"

    func testParsesWellFormedTickets() {
        let json = """
        {"tickets":[
          {"title":"Fix crash","description":"App crashes on launch","prompt":"Fix the crash in main()","priority":1},
          {"title":"Add tests","description":"","prompt":"Add unit tests for parser","priority":3}
        ]}
        """
        let tickets = TicketEngine.parseTickets(from: json, projectCwd: cwd)
        XCTAssertEqual(tickets.count, 2)
        XCTAssertEqual(tickets[0].title, "Fix crash")
        XCTAssertEqual(tickets[0].priority, 1)
        XCTAssertEqual(tickets[0].projectCwd, cwd)
        XCTAssertEqual(tickets[1].prompt, "Add unit tests for parser")
    }

    func testSortsByPriority() {
        let json = """
        {"tickets":[
          {"title":"Low","prompt":"p","priority":3},
          {"title":"High","prompt":"p","priority":1}
        ]}
        """
        let tickets = TicketEngine.parseTickets(from: json, projectCwd: cwd)
        XCTAssertEqual(tickets.map(\.title), ["High", "Low"])
    }

    func testParsesFencedJSON() {
        let fenced = """
        ```json
        {"tickets":[{"title":"T","prompt":"do it","priority":2}]}
        ```
        """
        let tickets = TicketEngine.parseTickets(from: fenced, projectCwd: cwd)
        XCTAssertEqual(tickets.count, 1)
        XCTAssertEqual(tickets[0].title, "T")
    }

    func testSkipsRowsMissingTitleOrPrompt() {
        let json = """
        {"tickets":[
          {"title":"","prompt":"p"},
          {"title":"No prompt"},
          {"title":"OK","prompt":"go"}
        ]}
        """
        let tickets = TicketEngine.parseTickets(from: json, projectCwd: cwd)
        XCTAssertEqual(tickets.map(\.title), ["OK"])
    }

    func testMalformedJSONYieldsEmpty() {
        XCTAssertTrue(TicketEngine.parseTickets(from: "not json", projectCwd: cwd).isEmpty)
        XCTAssertTrue(TicketEngine.parseTickets(from: "{\"other\":1}", projectCwd: cwd).isEmpty)
    }

    func testClampsCountPriorityAndPromptLength() {
        let rows = (0..<8).map {
            "{\"title\":\"T\($0)\",\"prompt\":\"\(String(repeating: "x", count: 5000))\",\"priority\":9}"
        }
        let json = "{\"tickets\":[\(rows.joined(separator: ","))]}"
        let tickets = TicketEngine.parseTickets(from: json, projectCwd: cwd)
        XCTAssertEqual(tickets.count, 5)
        XCTAssertTrue(tickets.allSatisfy { $0.priority == 3 })
        XCTAssertTrue(tickets.allSatisfy { $0.prompt.count == 4000 })
    }

    func testStripFencesPassthrough() {
        XCTAssertEqual(OpenRouterClient.stripFences("{\"a\":1}"), "{\"a\":1}")
    }
}
