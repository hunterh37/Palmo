import XCTest

final class PulseNarratorTests: XCTestCase {

    private func facts(cwd: String, live: Bool = false, done: Bool = false) -> ProjectFacts {
        ProjectFacts(cwd: cwd, name: (cwd as NSString).lastPathComponent, head: "h",
                     recentCommits: ["c"], dirtyCount: 0, hasLiveSession: live,
                     sessionDone: done, sessionLastMessage: "", canSend: false,
                     updatedAt: Date(timeIntervalSince1970: 1))
    }

    func testTemplateNarratorCoversEveryProject() async {
        let input = [facts(cwd: "/a", live: true), facts(cwd: "/b")]
        let out = await TemplateNarrator().narrate(input)
        XCTAssertEqual(Set(out.keys), ["/a", "/b"])
        XCTAssertFalse(out["/a"]!.headline.isEmpty)
    }

    // MARK: - Shared JSON parse

    func testParseWellFormed() {
        let json = """
        {"projects":[
          {"cwd":"/a","headline":"Waiting on you","detail":"Reply needed."},
          {"cwd":"/b","headline":"All caught up","detail":"Clean."}
        ]}
        """
        let out = PulseNarrationIO.parse(json)
        XCTAssertEqual(out["/a"]?.headline, "Waiting on you")
        XCTAssertEqual(out["/b"]?.detail, "Clean.")
    }

    func testParseFencedJSON() {
        let fenced = """
        ```json
        {"projects":[{"cwd":"/a","headline":"H","detail":"D"}]}
        ```
        """
        XCTAssertEqual(PulseNarrationIO.parse(fenced)["/a"]?.headline, "H")
    }

    func testParseSkipsRowsMissingCwdOrHeadline() {
        let json = """
        {"projects":[
          {"headline":"no cwd","detail":"d"},
          {"cwd":"/b","headline":"","detail":"d"},
          {"cwd":"/c","headline":"ok","detail":"d"}
        ]}
        """
        let out = PulseNarrationIO.parse(json)
        XCTAssertEqual(Set(out.keys), ["/c"])
    }

    func testParseMalformedYieldsEmpty() {
        XCTAssertTrue(PulseNarrationIO.parse("not json").isEmpty)
        XCTAssertTrue(PulseNarrationIO.parse("{\"other\":1}").isEmpty)
    }

    func testUserPromptIncludesStateAndCommits() {
        let prompt = PulseNarrationIO.userPrompt(for: [facts(cwd: "/a", live: true, done: true)])
        XCTAssertTrue(prompt.contains("/a"))
        XCTAssertTrue(prompt.contains("needsYou"))
        XCTAssertTrue(prompt.contains("awaiting reply"))
    }
}
