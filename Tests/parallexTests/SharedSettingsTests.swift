import XCTest
@testable import ParallexCore
import ParallexKit

/// Settings, not accounts: an editor copy's home links the original's
/// settings, sets its own aside meanwhile, and gets them back after.
final class SharedSettingsTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)
    let realHome = FileManager.default.homeDirectoryForCurrentUser.path
    /// A file every Mac has, only ever linked to (never written).
    let item = "Library/Preferences/.GlobalPreferences.plist"

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: realHome + "/" + item))
        tempDir = try Fixtures.makeTempDirectory("shared")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
        setenv("PARALLEX_LAUNCHER", Fixtures.launcherBinary.path, 1)
        setenv("PARALLEX_HOME_LIBRARY", Fixtures.homeLibrary.path, 1)
        setenv("PARALLEX_SHAREABLE_FOR", "com.fake.editor=\(item)", 1)
        outDir = tempDir.appendingPathComponent("apps", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        unsetenv("PARALLEX_LAUNCHER")
        unsetenv("PARALLEX_HOME_LIBRARY")
        unsetenv("PARALLEX_SHAREABLE_FOR")
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func launch(_ copy: URL) throws {
        let process = Process()
        process.executableURL = copy.appendingPathComponent("Contents/MacOS/parallex-launcher")
        try process.run()
        process.waitUntilExit()
    }

    func testAnEditorCopySharesTheOriginalsSettingsAndGetsItsOwnBack() throws {
        let app = try Fixtures.makeApp(named: "Editor", bundleID: "com.fake.editor", in: tempDir)
        var request = CreateRequest(appReference: app.path, name: "Editor Work", mode: .launchOnly, outputDirectory: outDir)
        request.cloneApp = true
        var manifest = try InstanceCreator.create(request, builderOptions: options).manifest
        let home = URL(fileURLWithPath: try XCTUnwrap(manifest.redirectedHome))
        let own = home.appendingPathComponent(item)
        try FileManager.default.createDirectory(at: own.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("the copy's own".utf8).write(to: own)

        var settings = manifest.effectiveSettings
        settings.shareSettings = true
        manifest = try InstanceCreator.update(manifest, InstanceUpdate(settings: settings), builderOptions: options).manifest
        XCTAssertEqual(manifest.sharedSettings, [item])
        XCTAssertTrue(manifest.guardedPaths?.contains("!\(realHome)/\(item)") == true, "Guard lets the copy use it")
        try launch(URL(fileURLWithPath: manifest.wrapperPath))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: own.path), "\(realHome)/\(item)")
        let aside = own.deletingLastPathComponent().appendingPathComponent(own.lastPathComponent + SettingsLinks.ownSuffix)
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "the copy's own")

        settings.shareSettings = nil
        manifest = try InstanceCreator.update(manifest, InstanceUpdate(settings: settings), builderOptions: options).manifest
        XCTAssertNil(manifest.sharedSettings)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: own.path))
        XCTAssertEqual(try String(contentsOf: own, encoding: .utf8), "the copy's own", "its own is back")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(realHome)/\(item)"), "yours untouched")
    }

    /// Turned off while it ran: the launcher undoes the links itself.
    func testTheLauncherUndoesLinksNoLongerShared() throws {
        let home = tempDir.appendingPathComponent("copy-home")
        let instance = tempDir.appendingPathComponent("instance")
        try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true)
        let real = URL(fileURLWithPath: realHome)
        SettingsLinks.sync([item], home: home, realHome: real, instance: instance)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: home.appendingPathComponent(item).path))
        SettingsLinks.sync([], home: home, realHome: real, instance: instance)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(item).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: instance.appendingPathComponent(SettingsLinks.markerFile).path))
    }
}
