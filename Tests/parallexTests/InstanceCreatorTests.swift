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

    // MARK: Update / rebuild

    private func wrapperConfig(_ wrapper: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: wrapper.appendingPathComponent("Contents/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return try XCTUnwrap(info[ParallexConfig.rootKey] as? [String: Any])
    }

    func testRebuildKeepsEverythingTheUserChose() throws {
        let codexApp = try Fixtures.makeApp(
            named: "FakeCodexApp", bundleID: "com.openai.codex", in: tempDir, electron: true
        )
        var request = CreateRequest(appReference: codexApp.path, name: "Codex Keep", outputDirectory: outDir)
        request.badgeText = "W"
        request.badgeColorHex = "#FF375F"
        request.environment = ["EXTRA": "1"]
        request.extraArguments = ["--flag"]
        let created = try InstanceCreator.create(request, builderOptions: options)

        let rebuilt = try InstanceCreator.update(created.manifest, builderOptions: options)
        XCTAssertEqual(rebuilt.manifest.settings, created.manifest.settings)
        XCTAssertEqual(rebuilt.manifest.environment, created.manifest.environment)
        XCTAssertEqual(rebuilt.manifest.arguments, ["--flag"])
        XCTAssertEqual(rebuilt.manifest.createdAt, created.manifest.createdAt)
        // The recipe survived (it used to be dropped for Codex).
        XCTAssertNotNil(rebuilt.manifest.environment["CODEX_ELECTRON_USER_DATA_PATH"])
        XCTAssertEqual(try wrapperConfig(rebuilt.wrapperURL)[ParallexConfig.Key.targetBundleID] as? String,
                       "com.openai.codex")
    }

    func testSchemaOneInstanceMigratesWithoutLosingItsRecipeOrIcon() throws {
        let codexApp = try Fixtures.makeApp(
            named: "FakeCodexApp", bundleID: "com.openai.codex", in: tempDir, electron: true
        )
        var request = CreateRequest(appReference: codexApp.path, name: "Codex Old", outputDirectory: outDir)
        request.environment = ["EXTRA": "1"]
        let created = try InstanceCreator.create(request, builderOptions: options)
        // Pretend it was written by 0.4: no settings, no bundle ID, a custom
        // (badged) icon in the wrapper.
        var legacy = created.manifest
        legacy.settings = nil
        legacy.targetBundleID = nil
        legacy.schemaVersion = 1
        try InstanceStore.save(legacy)
        let icon = created.wrapperURL.appendingPathComponent("Contents/Resources/app.icns")
        try Data("legacy-icon".utf8).write(to: icon)

        let migrated = legacy.effectiveSettings
        XCTAssertEqual(migrated.mode, .auto)
        XCTAssertEqual(migrated.extraEnvironment, ["EXTRA": "1"])

        let rebuilt = try InstanceCreator.update(legacy, builderOptions: options)
        XCTAssertEqual(rebuilt.manifest.schemaVersion, 2)
        XCTAssertNotNil(rebuilt.manifest.environment["CODEX_HOME"])
        XCTAssertEqual(rebuilt.manifest.environment["EXTRA"], "1")
        let newIcon = rebuilt.wrapperURL.appendingPathComponent("Contents/Resources/app.icns")
        XCTAssertEqual(try String(contentsOf: newIcon, encoding: .utf8), "legacy-icon")
    }

    func testSchemaOneFirefoxArgumentsMigrateCleanly() throws {
        let instance = Paths.instanceDir(slug: "fox").path
        XCTAssertEqual(
            InstanceManifest.userArguments(
                in: ["--no-remote", "--profile", "\(instance)/profile", "--kiosk"],
                instancePath: instance, preset: "firefox"
            ),
            ["--kiosk"]
        )
        XCTAssertEqual(
            InstanceManifest.userArguments(
                in: ["--user-data-dir=\(instance)/data", "--remote-debugging-port=9222"],
                instancePath: instance, preset: "electron"
            ),
            ["--remote-debugging-port=9222"]
        )
    }

    func testSchemaOneRecipeInstanceFindsItsRenamedApp() throws {
        // Codex was renamed to ChatGPT.app (same bundle ID). A 0.4 manifest
        // has no bundle ID, but its preset is the recipe ID = bundle ID.
        let codexApp = try Fixtures.makeApp(
            named: "FakeCodexApp", bundleID: "com.openai.codex", in: tempDir, electron: true
        )
        var legacy = try InstanceCreator.create(
            CreateRequest(appReference: codexApp.path, name: "Codex Moved", outputDirectory: outDir),
            builderOptions: options
        ).manifest
        legacy.settings = nil
        legacy.targetBundleID = nil
        XCTAssertEqual(legacy.knownTargetBundleID, "com.openai.codex")
    }

    func testRenameKeepsSlugAndRetiresOldWrapper() throws {
        let created = try InstanceCreator.create(makeRequest(), builderOptions: options)
        let renamed = try InstanceCreator.update(
            created.manifest, InstanceUpdate(name: "Fake Renamed"), builderOptions: options
        )
        XCTAssertEqual(renamed.manifest.slug, "fake-two")
        XCTAssertEqual(renamed.manifest.bundleIdentifier, created.manifest.bundleIdentifier)
        XCTAssertEqual(renamed.wrapperURL.lastPathComponent, "Fake Renamed.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.wrapperURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.wrapperURL.path))
        XCTAssertEqual(InstanceStore.find("Fake Renamed")?.slug, "fake-two")
    }

    func testCaseOnlyRenameKeepsTheWrapper() throws {
        let created = try InstanceCreator.create(makeRequest(), builderOptions: options)
        let renamed = try InstanceCreator.update(
            created.manifest, InstanceUpdate(name: "fake two"), builderOptions: options
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.wrapperURL.path))
        XCTAssertTrue(BundleBuilder.isParallexWrapper(renamed.wrapperURL))
    }

    func testRenameOntoAnotherAppIsRefused() throws {
        let created = try InstanceCreator.create(makeRequest(), builderOptions: options)
        try FileManager.default.createDirectory(
            at: outDir.appendingPathComponent("Taken.app"), withIntermediateDirectories: true
        )
        XCTAssertThrowsError(try InstanceCreator.update(
            created.manifest, InstanceUpdate(name: "Taken"), builderOptions: options
        ))
    }

    func testUpdateCanToggleRecipeOptions() throws {
        let claudeApp = try Fixtures.makeApp(
            named: "FakeClaude", bundleID: "com.anthropic.claudefordesktop", in: tempDir, electron: true
        )
        let created = try InstanceCreator.create(
            CreateRequest(appReference: claudeApp.path, name: "Claude Test", outputDirectory: outDir),
            builderOptions: options
        )
        XCTAssertNil(created.manifest.environment["CLAUDE_CONFIG_DIR"])
        var settings = created.manifest.effectiveSettings
        settings.enabledOptions = ["separate-claude-code"]
        let updated = try InstanceCreator.update(
            created.manifest, InstanceUpdate(settings: settings), builderOptions: options
        )
        XCTAssertEqual(
            updated.manifest.environment["CLAUDE_CONFIG_DIR"],
            Paths.instanceDir(slug: "claude-test").appendingPathComponent("claude-code").path
        )
    }

    func testUpdateRefusesADifferentApp() throws {
        let created = try InstanceCreator.create(makeRequest(), builderOptions: options)
        let other = try Fixtures.makeApp(named: "Other", bundleID: "com.fake.other", in: tempDir, electron: true)
        XCTAssertThrowsError(try InstanceCreator.update(
            created.manifest, InstanceUpdate(targetApp: other), builderOptions: options
        ))
    }

    // MARK: Adopting data and storage

    func testAdoptMovesExistingProfileIntoInstance() throws {
        let profile = tempDir.appendingPathComponent("Old-Profile")
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("Default"), withIntermediateDirectories: true)
        try Data("cookie".utf8).write(to: profile.appendingPathComponent("Default/Cookies"))

        var request = makeRequest()
        request.adoptData = profile
        let result = try InstanceCreator.create(request, builderOptions: options)

        let adopted = Paths.instanceDir(slug: "fake-two").appendingPathComponent("data/Default/Cookies")
        XCTAssertEqual(try String(contentsOf: adopted, encoding: .utf8), "cookie")
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.path))
        XCTAssertEqual(result.dataDirectories.first, adopted.deletingLastPathComponent().deletingLastPathComponent().path)
    }

    func testAdoptRejectsMissingFolder() throws {
        var request = makeRequest()
        request.adoptData = tempDir.appendingPathComponent("nope")
        XCTAssertThrowsError(try InstanceCreator.create(request, builderOptions: options))
        XCTAssertNil(InstanceStore.load(slug: "fake-two"), "nothing is created when validation fails")
    }

    func testStorageFindsCachesAndUnusedItems() throws {
        let created = try InstanceCreator.create(makeRequest(), builderOptions: options)
        let dir = Paths.instanceDir(slug: "fake-two")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("data/Cache"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10_000).write(to: dir.appendingPathComponent("data/Cache/blob"))
        try fm.createDirectory(at: dir.appendingPathComponent("data/Default/Code Cache"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10_000).write(to: dir.appendingPathComponent("data/Default/Code Cache/js"))
        try fm.createDirectory(at: dir.appendingPathComponent("home"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10_000).write(to: dir.appendingPathComponent("home/leftover"))
        // Something the app keeps next to its data: never "unused".
        try fm.createDirectory(at: dir.appendingPathComponent(".agents/skills"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10_000).write(to: dir.appendingPathComponent(".agents/skills/x"))

        let report = InstanceStorage.report(for: created.manifest)
        XCTAssertEqual(Set(report.caches.map(\.url.lastPathComponent)), ["Cache", "Code Cache"])
        XCTAssertEqual(report.unused.map(\.url.lastPathComponent), ["home"])
        XCTAssertGreaterThan(report.totalBytes, 0)

        XCTAssertThrowsError(try InstanceStorage.trash([tempDir.appendingPathComponent("elsewhere")], of: created.manifest))
        XCTAssertThrowsError(try InstanceStorage.trash([dir.appendingPathComponent(".agents")], of: created.manifest))
        XCTAssertThrowsError(try InstanceStorage.trash([dir.appendingPathComponent("data")], of: created.manifest))
    }

    func testStaleStorageListCannotTrashFolderNowInUse() throws {
        let claudeApp = try Fixtures.makeApp(
            named: "FakeClaude", bundleID: "com.anthropic.claudefordesktop", in: tempDir, electron: true
        )
        let created = try InstanceCreator.create(
            CreateRequest(appReference: claudeApp.path, name: "Claude Stale", outputDirectory: outDir),
            builderOptions: options
        )
        let leftover = Paths.instanceDir(slug: "claude-stale").appendingPathComponent("claude-code")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        let staleReport = InstanceStorage.report(for: created.manifest)
        XCTAssertEqual(staleReport.unused.map(\.url.lastPathComponent), ["claude-code"])

        // The option gets turned on after the report was taken…
        var settings = created.manifest.effectiveSettings
        settings.enabledOptions = ["separate-claude-code"]
        _ = try InstanceCreator.update(created.manifest, InstanceUpdate(settings: settings), builderOptions: options)

        // …so the stale list must not be honored.
        XCTAssertThrowsError(try InstanceStorage.trash(staleReport.unused.map(\.url), of: created.manifest))
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftover.path))
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
