import XCTest
@testable import ParallexCore
import ParallexKit

final class AppCatalogTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("catalog")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
        setenv("PARALLEX_LAUNCHER", Fixtures.launcherBinary.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        unsetenv("PARALLEX_LAUNCHER")
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testClassifiesAndOrdersInstalledApps() throws {
        let apps = tempDir.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try Fixtures.makeApp(named: "Zeta Native", bundleID: "com.fake.zeta", in: apps)
        try Fixtures.makeApp(named: "Alpha Electron", bundleID: "com.fake.alpha", in: apps, electron: true)
        try Fixtures.makeApp(named: "Claude", bundleID: "com.anthropic.claudefordesktop", in: apps, electron: true)
        try Fixtures.makeApp(named: "Notes", bundleID: "com.apple.Notes", in: apps)
        // Parallex's own bundles never show up.
        try Fixtures.makeApp(named: "Router", bundleID: "com.parallex.links", in: apps)
        try Fixtures.makeApp(named: "Wrapped", bundleID: "com.parallex.instance.x", in: apps,
                             extraInfoKeys: [ParallexConfig.rootKey: ["Slug": "x"]])

        let catalog = AppCatalog.scan(directories: [apps])
        // Best fit first; apps with a tuned recipe lead their tier.
        XCTAssertEqual(catalog.map(\.name), ["Claude", "Alpha Electron", "Zeta Native", "Notes"])
        XCTAssertEqual(catalog.map(\.fit), [.great, .great, .ownIdentity, .unsupported])
        XCTAssertFalse(catalog[1].recommendsClone)
        XCTAssertTrue(catalog[2].recommendsClone)
    }

    func testMetadataChangesSaveWithoutRebuilding() throws {
        let outDir = tempDir.appendingPathComponent("out")
        let target = try Fixtures.makeApp(named: "Meta", bundleID: "com.fake.meta", in: tempDir, electron: true)
        let created = try InstanceCreator.create(
            CreateRequest(appReference: target.path, name: "Meta Work", outputDirectory: outDir),
            builderOptions: BundleBuilder.Options(registerWithLaunchServices: false)
        )
        let original = created.manifest.effectiveSettings

        var launchOnly = original
        launchOnly.openAtLaunch = true
        launchOnly.badgeColorHex = "#30D158" // no badge: color is bookkeeping
        XCTAssertFalse(original.requiresRebuild(toReach: launchOnly))
        let saved = try InstanceCreator.saveSettings(launchOnly, for: created.manifest)
        XCTAssertEqual(InstanceStore.load(slug: "meta-work")?.settings?.openAtLaunch, true)
        XCTAssertEqual(saved.colorHex, "#30D158")

        var badged = launchOnly
        badged.badgeText = "W"
        XCTAssertTrue(launchOnly.requiresRebuild(toReach: badged))
        XCTAssertThrowsError(try InstanceCreator.saveSettings(badged, for: saved))
    }
}
