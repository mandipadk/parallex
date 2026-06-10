import XCTest
@testable import ParallexCore
import ParallexKit

/// Tests for the shared create/remove orchestration used by both the CLI and
/// the GUI. Uses the real built parallex-launcher (via PARALLEX_LAUNCHER) so
/// created wrappers are genuine, runnable artifacts.
final class InstanceCreatorTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    var targetApp: URL!

    /// Skip lsregister so test wrappers don't pollute Launch Services.
    let options = BundleBuilder.Options(registerWithLaunchServices: false)

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("creator")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
        setenv("PARALLEX_LAUNCHER", Fixtures.launcherBinary.path, 1)
        outDir = tempDir.appendingPathComponent("apps", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        targetApp = try Fixtures.makeApp(
            named: "FakeTarget", bundleID: "com.fake.target", in: tempDir, electron: true
        )
    }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        unsetenv("PARALLEX_LAUNCHER")
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeRequest(name: String? = "Fake Two") -> CreateRequest {
        CreateRequest(
            appReference: targetApp.path,
            name: name,
            outputDirectory: outDir
        )
    }

    func testCreateBuildsWrapperAndManifest() throws {
        let result = try InstanceCreator.create(makeRequest(), builderOptions: options)

        XCTAssertEqual(result.manifest.name, "Fake Two")
        XCTAssertEqual(result.manifest.slug, "fake-two")
        XCTAssertEqual(result.manifest.mode, .dataDir)
        XCTAssertEqual(result.manifest.preset, "electron")
        XCTAssertEqual(result.manifest.environment["PARALLEX_INSTANCE"], "fake-two")
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")

        // Wrapper exists and is recognized as ours.
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.wrapperURL.path))
        XCTAssertTrue(BundleBuilder.isParallexWrapper(result.wrapperURL))

        // Manifest is persisted and findable.
        XCTAssertNotNil(InstanceStore.load(slug: "fake-two"))
        XCTAssertNotNil(InstanceStore.find("Fake Two"))
    }

    func testCreatedWrapperActuallyLaunchesTarget() throws {
        // Swap the fixture's executable for a script that proves it ran and
        // received the configured environment.
        let witness = tempDir.appendingPathComponent("witness.txt")
        let script = "#!/bin/sh\nprintf '%s' \"$PARALLEX_INSTANCE\" > \"\(witness.path)\"\n"
        let executable = targetApp.appendingPathComponent("Contents/MacOS/FakeTarget")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let result = try InstanceCreator.create(makeRequest(), builderOptions: options)

        // Run the wrapper's launcher directly (what Launch Services would exec).
        let process = Process()
        process.executableURL = result.wrapperURL.appendingPathComponent("Contents/MacOS/launcher")
        var env = ProcessInfo.processInfo.environment
        env["PARALLEX_LAUNCHER_NO_UI"] = "1"
        process.environment = env
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: witness, encoding: .utf8), "fake-two")
    }

    func testDefaultNameAutoIncrements() throws {
        let first = try InstanceCreator.create(makeRequest(name: nil), builderOptions: options)
        XCTAssertEqual(first.manifest.name, "FakeTarget 2")
        let second = try InstanceCreator.create(makeRequest(name: nil), builderOptions: options)
        XCTAssertEqual(second.manifest.name, "FakeTarget 3")
    }

    func testDuplicateNameNeedsForce() throws {
        _ = try InstanceCreator.create(makeRequest(), builderOptions: options)
        XCTAssertThrowsError(try InstanceCreator.create(makeRequest(), builderOptions: options)) { error in
            XCTAssertTrue("\(error)".contains("already exists"))
        }
        // Force rebuilds in place.
        var forced = makeRequest()
        forced.force = true
        let result = try InstanceCreator.create(forced, builderOptions: options)
        XCTAssertEqual(result.manifest.slug, "fake-two")
    }

    func testRefusesToWrapAWrapper() throws {
        let first = try InstanceCreator.create(makeRequest(), builderOptions: options)
        var request = makeRequest(name: "Wrapper of Wrapper")
        request.appReference = first.wrapperURL.path
        XCTAssertThrowsError(try InstanceCreator.create(request, builderOptions: options)) { error in
            XCTAssertTrue("\(error)".contains("itself a Parallex wrapper"))
        }
    }

    func testInvalidBadgeIsRejected() throws {
        var request = makeRequest()
        request.badgeText = "TOO LONG"
        XCTAssertThrowsError(try InstanceCreator.create(request, builderOptions: options))

        var badColor = makeRequest()
        badColor.badgeText = "W"
        badColor.badgeColorHex = "nope"
        XCTAssertThrowsError(try InstanceCreator.create(badColor, builderOptions: options))
    }

    func testOverrideEnvRecipeFlowsIntoWrapper() throws {
        // An app with a per-app env recipe (Codex) gets the recipe baked into
        // its wrapper config; user-provided env still wins on conflicts.
        let codexApp = try Fixtures.makeApp(
            named: "FakeCodexApp", bundleID: "com.openai.codex", in: tempDir, electron: true
        )
        var request = CreateRequest(
            appReference: codexApp.path,
            name: "Codex Test",
            outputDirectory: outDir
        )
        request.environment = ["CODEX_HOME": "/custom/codex-home", "EXTRA": "1"]
        let result = try InstanceCreator.create(request, builderOptions: options)

        XCTAssertEqual(result.manifest.preset, "com.openai.codex")
        XCTAssertTrue(result.manifest.arguments.isEmpty)
        // Recipe value present…
        XCTAssertEqual(
            result.manifest.environment["CODEX_ELECTRON_USER_DATA_PATH"],
            Paths.instanceDir(slug: "codex-test").appendingPathComponent("data").path
        )
        // …user override wins…
        XCTAssertEqual(result.manifest.environment["CODEX_HOME"], "/custom/codex-home")
        XCTAssertEqual(result.manifest.environment["EXTRA"], "1")
        XCTAssertEqual(result.manifest.environment["PARALLEX_INSTANCE"], "codex-test")

        // …and the wrapper's Info.plist carries the merged environment.
        let data = try Data(contentsOf: result.wrapperURL.appendingPathComponent("Contents/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let config = try XCTUnwrap(info[ParallexConfig.rootKey] as? [String: Any])
        let environment = try XCTUnwrap(config[ParallexConfig.Key.environment] as? [String: String])
        XCTAssertEqual(environment["CODEX_HOME"], "/custom/codex-home")
        XCTAssertNotNil(environment["CODEX_ELECTRON_USER_DATA_PATH"])
    }

    func testProbeReportsRecommendation() throws {
        let probe = try InstanceCreator.probe(appAt: targetApp, outputDirectory: outDir)
        XCTAssertEqual(probe.name, "FakeTarget")
        XCTAssertEqual(probe.recommendedMode, .dataDir)
        XCTAssertEqual(probe.frameworkDisplayName, "Electron app")
        XCTAssertFalse(probe.sandboxed)
        XCTAssertEqual(probe.suggestedName, "FakeTarget 2")
    }

    func testRemoveTrashesWrapperAndData() throws {
        let created = try InstanceCreator.create(makeRequest(), builderOptions: options)
        let result = try InstanceRemover.remove(created.manifest, keepData: false)
        XCTAssertTrue(result.wrapperTrashed)
        XCTAssertTrue(result.dataTrashed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.wrapperURL.path))
        XCTAssertNil(InstanceStore.load(slug: "fake-two"))
    }

    func testRemoveKeepDataLeavesDataBehind() throws {
        let created = try InstanceCreator.create(makeRequest(), builderOptions: options)
        // Simulate the instance having data.
        let dataDir = Paths.instanceDir(slug: "fake-two").appendingPathComponent("data")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let result = try InstanceRemover.remove(created.manifest, keepData: true)
        XCTAssertTrue(result.wrapperTrashed)
        XCTAssertFalse(result.dataTrashed)
        XCTAssertNotNil(result.dataKeptAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataDir.path))
        // But the instance is forgotten.
        XCTAssertNil(InstanceStore.load(slug: "fake-two"))
    }
}
