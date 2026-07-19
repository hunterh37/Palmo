import XCTest

/// Reply-drafting engine: git-diff context gathering (real temp repos) and
/// lifecycle state. Actual model output is only smoke-tested when the
/// on-device foundation model is available on the test machine.
final class ReplyPresetEngineTests: XCTestCase {

    // MARK: gitDiff context helper

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("palmo-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func git(_ args: [String], in dir: URL) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    func testGitDiffCapturesUncommittedChanges() async throws {
        let dir = try makeTempDir()
        try git(["init"], in: dir)
        try git(["config", "user.email", "t@t.t"], in: dir)
        try git(["config", "user.name", "t"], in: dir)
        let file = dir.appendingPathComponent("main.swift")
        try "let x = 1\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "."], in: dir)
        try git(["commit", "-m", "init"], in: dir)
        try "let x = 2\n".write(to: file, atomically: true, encoding: .utf8)

        let diff = await ReplyPresetEngine.gitDiff(cwd: dir.path)
        XCTAssertTrue(diff.contains("-let x = 1"))
        XCTAssertTrue(diff.contains("+let x = 2"))
    }

    func testGitDiffOfNonRepoIsEmpty() async throws {
        let dir = try makeTempDir()
        let diff = await ReplyPresetEngine.gitDiff(cwd: dir.path)
        XCTAssertEqual(diff, "")
    }

    func testGitDiffOfEmptyPathIsEmpty() async {
        let diff = await ReplyPresetEngine.gitDiff(cwd: "")
        XCTAssertEqual(diff, "")
    }

    // MARK: Lifecycle

    @MainActor
    func testCancelClearsPresetsAndStopsGenerating() {
        let engine = ReplyPresetEngine()
        engine.start(context: ComposeContext(sessionName: "t", cwd: "",
                                             lastMessage: "hi", diff: ""))
        engine.cancel()
        XCTAssertFalse(engine.isGenerating)
        XCTAssertTrue(engine.presets.isEmpty)
    }

    @MainActor
    func testStartWithoutModelFinishesCleanly() async throws {
        try XCTSkipIf(ReplyPresetEngine.isAvailable,
                      "covers the model-unavailable path only")
        let engine = ReplyPresetEngine()
        engine.start(context: ComposeContext(sessionName: "t", cwd: "",
                                             lastMessage: "hi", diff: ""))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(engine.isGenerating)
        XCTAssertTrue(engine.presets.isEmpty)
    }

    /// Real on-device generation smoke test — runs only where Apple
    /// Intelligence is available, and tolerates slow first-token times.
    @MainActor
    func testGeneratesQuickRepliesWhenModelAvailable() async throws {
        try XCTSkipUnless(ReplyPresetEngine.isAvailable, "on-device model unavailable")
        let engine = ReplyPresetEngine()
        engine.start(context: ComposeContext(
            sessionName: "demo", cwd: "",
            lastMessage: "I fixed the bug. Should I also run the full test suite?",
            diff: ""))
        for _ in 0..<600 {  // up to 60s
            try await Task.sleep(nanoseconds: 100_000_000)
            if !engine.presets.isEmpty { break }
        }
        XCTAssertFalse(engine.presets.isEmpty, "expected at least one drafted reply")
        XCTAssertTrue(engine.presets.allSatisfy { !$0.text.isEmpty })
        engine.cancel()
    }
}
