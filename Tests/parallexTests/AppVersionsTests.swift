import XCTest
@testable import ParallexCore
import ParallexKit

/// A copy keeps the app version it was built from, so when the app
/// updates it can go back to it, data included, and forward again.
final class AppVersionsTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("versions")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
        setenv("PARALLEX_LAUNCHER", Fixtures.launcherBinary.path, 1)
        setenv("PARALLEX_HOME_LIBRARY", Fixtures.homeLibrary.path, 1)
        setenv("PARALLEX_TRASH", tempDir.appendingPathComponent("trash").path, 1)
        outDir = tempDir.appendingPathComponent("apps", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        unsetenv("PARALLEX_LAUNCHER")
        unsetenv("PARALLEX_HOME_LIBRARY")
        unsetenv("PARALLEX_TRASH")
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// The app in "/Applications" updates to `version`.
    private func update(_ app: URL, to version: String) throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        var info = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any])
        info["CFBundleShortVersionString"] = version
        info["CFBundleVersion"] = version
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
    }

    private func version(_ number: String) -> String { "\(number) (\(number))" }

    private func dataFile(_ manifest: InstanceManifest) throws -> URL {
        URL(fileURLWithPath: try XCTUnwrap(manifest.redirectedHome)).appendingPathComponent("Library/state.txt")
    }

    func testGoingBackToTheVersionBeforeAnUpdateAndItsData() throws {
        let app = try Fixtures.makeApp(named: "Movey", bundleID: "com.fake.movey", in: tempDir)
        try update(app, to: "1.0")
        var request = CreateRequest(appReference: app.path, name: "Movey Work", mode: .launchOnly, outputDirectory: outDir)
        request.cloneApp = true
        let made = try InstanceCreator.create(request, builderOptions: options).manifest
        XCTAssertEqual(AppVersions.list(made).map(\.version), [version("1.0")], "the version it's built from is kept")
        try FileManager.default.createDirectory(at: try dataFile(made).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("as 1.0 left it".utf8).write(to: try dataFile(made))

        // The app updates, and the copy with it.
        try update(app, to: "2.0")
        XCTAssertTrue(InstanceStatus.check(made).problems.contains { if case .cloneOutdated = $0 { true } else { false } })
        let refreshed = try InstanceCreator.update(made, builderOptions: options).manifest
        XCTAssertEqual(refreshed.clone?.sourceVersion, version("2.0"))
        XCTAssertEqual(Set(AppVersions.list(refreshed).map(\.version)), [version("1.0"), version("2.0")])
        XCTAssertNotNil(AppVersions.snapshotBefore(leaving: version("1.0"), of: refreshed), "its data as 1.0 left it")
        try Data("migrated by 2.0".utf8).write(to: try dataFile(refreshed))

        // Back to 1.0, data included; it stays there while the app is 2.0.
        let back = try AppVersions.use(version("1.0"), for: refreshed, restoreData: true, builderOptions: options)
        XCTAssertEqual(back.clone?.sourceVersion, version("1.0"))
        XCTAssertEqual(back.effectiveSettings.pinnedVersion, version("1.0"))
        XCTAssertEqual(back.targetApp, app.path, "still the copy of the app in /Applications")
        XCTAssertEqual(try String(contentsOf: try dataFile(back), encoding: .utf8), "as 1.0 left it")
        XCTAssertTrue(InstanceStatus.check(back).problems.isEmpty, "\(InstanceStatus.check(back).problems)")
        let copyInfo = URL(fileURLWithPath: back.wrapperPath).appendingPathComponent("Contents/Info.plist")
        XCTAssertEqual((NSDictionary(contentsOf: copyInfo) as? [String: Any])?["CFBundleShortVersionString"] as? String, "1.0")

        // A new Parallex rebuilds it from 1.0 still.
        let rebuilt = try InstanceCreator.update(back, builderOptions: options).manifest
        XCTAssertEqual(rebuilt.clone?.sourceVersion, version("1.0"))

        // And forward again.
        let forward = try AppVersions.use(version("2.0"), for: rebuilt, builderOptions: options)
        XCTAssertEqual(forward.clone?.sourceVersion, version("2.0"))
        XCTAssertNil(forward.effectiveSettings.pinnedVersion)
    }

    func testOnlyThePreviousVersionIsKeptUnlessPinned() throws {
        let app = try Fixtures.makeApp(named: "Keepy", bundleID: "com.fake.keepy", in: tempDir)
        try update(app, to: "1.0")
        var request = CreateRequest(appReference: app.path, name: "Keepy Work", mode: .launchOnly, outputDirectory: outDir)
        request.cloneApp = true
        var manifest = try InstanceCreator.create(request, builderOptions: options).manifest
        for next in ["2.0", "3.0"] {
            try update(app, to: next)
            manifest = try InstanceCreator.update(manifest, builderOptions: options).manifest
        }
        XCTAssertEqual(AppVersions.list(manifest).map(\.version), [version("3.0"), version("2.0")])

        var settings = manifest.effectiveSettings
        settings.keepPreviousVersion = false
        XCTAssertFalse(manifest.effectiveSettings.requiresRebuild(toReach: settings), "a preference, not a rebuild")
        manifest = try InstanceCreator.update(manifest, InstanceUpdate(settings: settings), builderOptions: options).manifest
        XCTAssertEqual(AppVersions.list(manifest).map(\.version), [version("3.0")])
        XCTAssertThrowsError(try AppVersions.use(version("2.0"), for: manifest, builderOptions: options))
    }

    /// On 1.0 (pinned there after 2.0 was bad), the app moves to 3.0 and the
    /// copy with it: 1.0, the version it left, is the way back, not 2.0.
    func testTheVersionLeftIsAlwaysTheWayBack() throws {
        let app = try Fixtures.makeApp(named: "Pinny", bundleID: "com.fake.pinny", in: tempDir)
        try update(app, to: "1.0")
        var request = CreateRequest(appReference: app.path, name: "Pinny Work", mode: .launchOnly, outputDirectory: outDir)
        request.cloneApp = true
        var manifest = try InstanceCreator.create(request, builderOptions: options).manifest
        try update(app, to: "2.0")
        manifest = try InstanceCreator.update(manifest, builderOptions: options).manifest
        manifest = try AppVersions.use("1.0", for: manifest, builderOptions: options)
        XCTAssertEqual(manifest.clone?.sourceVersion, version("1.0"), "the short version is enough")
        try update(app, to: "3.0")
        manifest = try AppVersions.use("3.0", for: manifest, builderOptions: options)
        XCTAssertEqual(manifest.clone?.sourceVersion, version("3.0"))
        XCTAssertEqual(Set(AppVersions.list(manifest).map(\.version)), [version("3.0"), version("1.0")])
        XCTAssertThrowsError(try AppVersions.use("3.0", for: manifest, restoreData: true, builderOptions: options),
                             "already on it")
    }

    func testKeptVersionsAreNotTheInstancesData() throws {
        let app = try Fixtures.makeApp(named: "Aparty", bundleID: "com.fake.aparty", in: tempDir)
        var request = CreateRequest(appReference: app.path, name: "Aparty Work", mode: .launchOnly, outputDirectory: outDir)
        request.cloneApp = true
        let manifest = try InstanceCreator.create(request, builderOptions: options).manifest
        XCTAssertFalse(AppVersions.list(manifest).isEmpty)
        let snapshot = try Snapshots.take(manifest)
        let kept = Snapshots.folder(slug: manifest.slug).appendingPathComponent(snapshot.id).appendingPathComponent("data")
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.appendingPathComponent(AppVersions.folderName).path))
        let report = InstanceStorage.report(for: manifest)
        XCTAssertGreaterThan(report.versionBytes, 0)
        let twin = try InstanceCreator.duplicate(manifest, includeData: true, builderOptions: options)
        XCTAssertEqual(AppVersions.list(twin.manifest).map(\.version), AppVersions.list(manifest).map(\.version),
                       "a duplicate keeps its own, from its own build")
    }
}
