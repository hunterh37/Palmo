import XCTest

/// Orb-ring construction from user-chosen bundle IDs.
final class MenuActionTests: XCTestCase {

    func testRingAlwaysEndsWithPlayPauseAndAssistant() {
        let ring = MenuAction.ring(bundleIDs: [])
        XCTAssertEqual(ring.map(\.id).suffix(2), ["playpause", "assistant"])
    }

    func testRingDropsAppsNotInstalled() {
        let ring = MenuAction.ring(bundleIDs: ["com.definitely.not.installed.xyz"])
        XCTAssertFalse(ring.contains { $0.id == "com.definitely.not.installed.xyz" })
        XCTAssertEqual(ring.count, 2, "only the two built-in orbs remain")
    }

    func testRingKeepsInstalledAppsWithNames() throws {
        // Safari ships with every macOS install.
        let ring = MenuAction.ring(bundleIDs: ["com.apple.Safari"])
        let safari = try XCTUnwrap(ring.first { $0.id == "com.apple.Safari" })
        XCTAssertEqual(safari.name, "Safari")
        XCTAssertNotNil(safari.appURL)
        XCTAssertEqual(ring.count, 3)
    }

    func testRingCapsAtEightApps() {
        // 10 copies of an installed app: only 8 make it in (+2 built-ins).
        let ring = MenuAction.ring(bundleIDs: Array(repeating: "com.apple.Safari", count: 10))
        XCTAssertEqual(ring.count, 8 + 2)
    }

    func testDefaultRingIsNonEmptyAndInFrameActions() {
        let ring = MenuAction.ring(bundleIDs: MenuAction.defaultBundleIDs)
        XCTAssertGreaterThanOrEqual(ring.count, 2)
        for action in ring where action.appURL != nil {
            XCTAssertFalse(action.name.isEmpty)
        }
    }
}
