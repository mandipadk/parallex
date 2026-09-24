import XCTest
@testable import ParallexCore

final class CompatibilityTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("compat")
        setenv("PARALLEX_HOME", tempDir.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testQuickExitsAreRememberedPerVersion() {
        XCTAssertFalse(Compatibility.refusesCopies(bundleID: "com.fake.store", version: "1.0 (1)"))
        Compatibility.recordQuickExit(bundleID: "com.fake.store", version: "1.0 (1)")
        XCTAssertTrue(Compatibility.refusesCopies(bundleID: "com.fake.store", version: "1.0 (1)"))
        XCTAssertFalse(Compatibility.refusesCopies(bundleID: "com.fake.store", version: "2.0 (2)"), "a new version gets a fresh chance")
        Compatibility.recordHealthyRun(bundleID: "com.fake.store")
        XCTAssertFalse(Compatibility.refusesCopies(bundleID: "com.fake.store", version: "1.0 (1)"))
    }

    func testCatalogWarnsAboutAppsWhoseCopiesQuit() throws {
        let app = try Fixtures.makeApp(named: "Picky", bundleID: "com.fake.picky", in: tempDir,
                                       extraInfoKeys: ["CFBundleShortVersionString": "3.1", "CFBundleVersion": "7"])
        let info = try AppInspector.inspect(app)
        XCTAssertNotEqual(AppCatalog.entry(for: info).fit, .limited)
        Compatibility.recordQuickExit(bundleID: "com.fake.picky", version: AppCloner.version(of: app))
        let entry = AppCatalog.entry(for: info, compatibility: Compatibility.load())
        XCTAssertEqual(entry.fit, .limited)
        XCTAssertFalse(entry.recommendsClone)
    }
}
