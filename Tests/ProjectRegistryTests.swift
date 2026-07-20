import XCTest

@MainActor
final class ProjectRegistryTests: XCTestCase {
    private var dir: URL!
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("palmo-registry-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("projects.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// A real directory to register (the temp dir itself).
    private var realCwd: String { dir.path }

    func testRegisterPersistsAndReloads() {
        let registry = ProjectRegistry(fileURL: fileURL)
        XCTAssertNotNil(registry.register(cwd: realCwd))
        XCTAssertEqual(registry.projects.count, 1)

        let reloaded = ProjectRegistry(fileURL: fileURL)
        reloaded.load()
        XCTAssertEqual(reloaded.projects.map(\.cwd), [realCwd])
    }

    func testRegisterDedupesByStandardizedPath() {
        let registry = ProjectRegistry(fileURL: fileURL)
        registry.register(cwd: realCwd)
        registry.register(cwd: realCwd + "/")
        registry.register(cwd: realCwd + "/./")
        XCTAssertEqual(registry.projects.count, 1)
    }

    func testRejectsMissingAndEmptyPaths() {
        let registry = ProjectRegistry(fileURL: fileURL)
        XCTAssertNil(registry.register(cwd: ""))
        XCTAssertNil(registry.register(cwd: "/nope/definitely/missing"))
        XCTAssertTrue(registry.projects.isEmpty)
    }

    func testRemove() {
        let registry = ProjectRegistry(fileURL: fileURL)
        registry.register(cwd: realCwd)
        registry.remove(cwd: realCwd)
        XCTAssertTrue(registry.projects.isEmpty)
        let reloaded = ProjectRegistry(fileURL: fileURL)
        reloaded.load()
        XCTAssertTrue(reloaded.projects.isEmpty)
    }

    func testUpdateHeadRoundTrips() {
        let registry = ProjectRegistry(fileURL: fileURL)
        registry.register(cwd: realCwd)
        registry.updateHead(cwd: realCwd, head: "abc123")
        let reloaded = ProjectRegistry(fileURL: fileURL)
        reloaded.load()
        XCTAssertEqual(reloaded.projects.first?.lastSeenHead, "abc123")
    }

    func testCurrentHeadReadsDetachedAndRefHeads() throws {
        let gitDir = dir.appendingPathComponent(".git")
        let refsDir = gitDir.appendingPathComponent("refs/heads")
        try FileManager.default.createDirectory(at: refsDir, withIntermediateDirectories: true)

        // Detached HEAD: file contains a bare hash.
        try "deadbeef".write(to: gitDir.appendingPathComponent("HEAD"),
                             atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectRegistry.currentHead(cwd: dir.path), "deadbeef")

        // Symbolic ref: HEAD points at a branch ref file.
        try "ref: refs/heads/main\n".write(to: gitDir.appendingPathComponent("HEAD"),
                                           atomically: true, encoding: .utf8)
        try "cafef00d\n".write(to: refsDir.appendingPathComponent("main"),
                               atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectRegistry.currentHead(cwd: dir.path), "cafef00d")
    }

    func testCurrentHeadNilForNonRepo() {
        XCTAssertNil(ProjectRegistry.currentHead(cwd: dir.path + "-not-a-repo"))
    }
}
