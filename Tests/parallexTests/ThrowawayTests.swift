import XCTest
@testable import ParallexCore
import ParallexKit

/// Throwaways go once they've run and quit, and only then.
final class ThrowawayTests: XCTestCase {
    var tempDir: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("throwaway")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
        setenv("PARALLEX_LAUNCHER", Fixtures.launcherBinary.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        unsetenv("PARALLEX_LAUNCHER")
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func make(_ name: String, throwaway: Bool) throws -> InstanceManifest {
        let app = try Fixtures.makeApp(named: name, bundleID: "com.fake.\(name.lowercased())", in: tempDir)
        var request = CreateRequest(appReference: app.path, name: "\(name) Instance", outputDirectory: tempDir)
        request.throwaway = throwaway
        return try InstanceCreator.create(request, builderOptions: options).manifest
    }

    /// As if it ran: the launcher leaves its pid file behind (a pid that's
    /// long gone), written `ago` seconds back.
    private func markRan(_ manifest: InstanceManifest, ago: TimeInterval = 60) throws {
        let file = Paths.pidFile(slug: manifest.slug)
        try "99999".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ago)], ofItemAtPath: file.path)
    }

    /// A throwaway made or turned on "now", as far as its runs go.
    private func armed(_ manifest: InstanceManifest, ago: TimeInterval) throws -> InstanceManifest {
        var manifest = manifest
        manifest.settings?.throwawaySince = Date().addingTimeInterval(-ago)
        try InstanceStore.save(manifest)
        return manifest
    }

    func testOnlyFinishedThrowawaysGo() throws {
        let fresh = try armed(make("Fresh", throwaway: true), ago: 120)
        let used = try armed(make("Used", throwaway: true), ago: 120)
        let kept = try make("Kept", throwaway: false)
        try markRan(used)
        try markRan(kept)
        XCTAssertNotNil(fresh.settings?.throwawaySince)
        XCTAssertEqual(Throwaway.finished([fresh, used, kept]).map(\.slug), [used.slug], "never opened, or not a throwaway, stays")
    }

    /// A run that's only just started (the launcher is becoming the app)
    /// isn't over.
    func testAJustStartedRunIsntTheEnd() throws {
        let manifest = try armed(make("Starting", throwaway: true), ago: 120)
        try markRan(manifest, ago: 2)
        XCTAssertFalse(Throwaway.isFinished(manifest))
    }

    /// A pid file from before it was a throwaway (kept data under the same
    /// name, or a run already going when it was turned on) doesn't count.
    func testOnlyRunsSinceItBecameAThrowawayCount() throws {
        let leftover = try make("Leftover", throwaway: false)
        try markRan(leftover, ago: 600)
        var request = CreateRequest(appReference: leftover.targetApp, name: "Leftover Instance", outputDirectory: tempDir)
        request.throwaway = true
        request.force = true
        let remade = try InstanceCreator.create(request, builderOptions: options).manifest
        XCTAssertEqual(remade.slug, leftover.slug)
        XCTAssertFalse(Throwaway.isFinished(remade), "the old run was before it became a throwaway")

        let later = try make("Later", throwaway: false)
        try markRan(later, ago: 300)
        var settings = later.effectiveSettings
        settings.throwaway = true
        XCTAssertFalse(later.effectiveSettings.requiresRebuild(toReach: settings), "no rebuild needed")
        let saved = try InstanceCreator.saveSettings(settings, for: later)
        XCTAssertFalse(Throwaway.isFinished(saved))
        let again = try InstanceCreator.saveSettings(saved.effectiveSettings, for: saved)
        XCTAssertEqual(again.settings?.throwawaySince, saved.settings?.throwawaySince, "stays armed from when it was turned on")

        var off = saved.effectiveSettings
        off.throwaway = false
        XCTAssertNil(try InstanceCreator.saveSettings(off, for: saved).settings?.throwawaySince)
    }

    func testAThrowawayCopyOfAnInstance() throws {
        let original = try make("Base", throwaway: false)
        let copy = try InstanceCreator.duplicate(original, throwaway: true, builderOptions: options).manifest
        XCTAssertEqual(copy.name, "Base Instance Throwaway")
        XCTAssertEqual(copy.settings?.throwaway, true)
        XCTAssertNil(original.settings?.throwaway)
    }
}
