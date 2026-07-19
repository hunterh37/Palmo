import XCTest

/// Session model + the hook-file → session pipeline. Store tests write
/// uniquely-named files into the real watched directory and always clean up.
@MainActor
final class ClaudeSessionStoreTests: XCTestCase {
    private var testID: String!
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        testID = "palmo-test-\(UUID().uuidString)"
        fileURL = ClaudeSessionStore.sessionsDir
            .appendingPathComponent("\(testID!).json")
        try? FileManager.default.createDirectory(at: ClaudeSessionStore.sessionsDir,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func writeSessionFile(status: String = "done",
                                  updatedAt: TimeInterval = Date().timeIntervalSince1970,
                                  port: Any? = 4242) throws {
        var obj: [String: Any] = [
            "session_id": testID!,
            "cwd": "/tmp/my-project",
            "status": status,
            "updated_at": updatedAt,
            "last_message": "All tests pass.",
        ]
        if let port { obj["port"] = port }
        let data = try JSONSerialization.data(withJSONObject: obj)
        try data.write(to: fileURL)
    }

    // MARK: Model

    func testSessionNameIsLastPathComponentOfCwd() {
        let s = ClaudeSession(id: "x", cwd: "/Users/dev/cool-app", isDone: false,
                              updatedAt: .now, lastMessage: "", port: nil)
        XCTAssertEqual(s.name, "cool-app")
    }

    func testEmptyCwdFallsBackToClaude() {
        let s = ClaudeSession(id: "x", cwd: "", isDone: false,
                              updatedAt: .now, lastMessage: "", port: nil)
        XCTAssertEqual(s.name, "Claude")
    }

    func testCanSendRequiresPort() {
        var s = ClaudeSession(id: "x", cwd: "/tmp", isDone: true,
                              updatedAt: .now, lastMessage: "", port: 9999)
        XCTAssertTrue(s.canSend)
        s.port = nil
        XCTAssertFalse(s.canSend)
    }

    // MARK: Store (hook file → published session)

    func testStoreParsesHookFile() throws {
        try writeSessionFile()
        let store = ClaudeSessionStore()
        store.start()
        let session = try XCTUnwrap(store.sessions.first { $0.id == testID })
        XCTAssertEqual(session.name, "my-project")
        XCTAssertTrue(session.isDone)
        XCTAssertEqual(session.lastMessage, "All tests pass.")
        XCTAssertEqual(session.port, 4242)
    }

    func testWorkingStatusAndFloatPortParse() throws {
        try writeSessionFile(status: "working", port: 4242.0)  // JSON double
        let store = ClaudeSessionStore()
        store.start()
        let session = try XCTUnwrap(store.sessions.first { $0.id == testID })
        XCTAssertFalse(session.isDone)
        XCTAssertEqual(session.port, 4242)
    }

    func testStaleSessionsAreSweptAndDeleted() throws {
        let dayOld = Date().timeIntervalSince1970 - 24 * 60 * 60
        try writeSessionFile(updatedAt: dayOld)
        let store = ClaudeSessionStore()
        store.start()
        XCTAssertFalse(store.sessions.contains { $0.id == testID })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "stale hook files should be deleted from disk")
    }

    func testAcknowledgeRemovesSessionAndFile() throws {
        try writeSessionFile()
        let store = ClaudeSessionStore()
        store.start()
        XCTAssertTrue(store.sessions.contains { $0.id == testID })
        store.acknowledge(testID)
        XCTAssertFalse(store.sessions.contains { $0.id == testID })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testMalformedFileIsIgnored() throws {
        try Data("not json".utf8).write(to: fileURL)
        let store = ClaudeSessionStore()
        store.start()
        XCTAssertFalse(store.sessions.contains { $0.id == testID })
    }
}
