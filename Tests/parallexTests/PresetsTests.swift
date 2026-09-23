import XCTest
@testable import ParallexCore

final class PresetsTests: XCTestCase {
    var tempDir: URL!
    var instanceDir: URL!

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("presets")
        instanceDir = tempDir.appendingPathComponent("instance")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func plan(
        for app: URL,
        requested: RequestedMode = .auto,
        sharedItems: [String] = Presets.defaultSharedItems
    ) throws -> IsolationPlan {
        let info = try AppInspector.inspect(app)
        return Presets.plan(for: info, requested: requested, instanceDir: instanceDir, sharedItems: sharedItems)
    }

    func testElectronGetsUserDataDir() throws {
        let app = try Fixtures.makeApp(named: "FakeSlack", bundleID: "com.fake.slack", in: tempDir, electron: true)
        let plan = try plan(for: app)
        XCTAssertEqual(plan.mode, .dataDir)
        XCTAssertEqual(plan.preset(), "electron")
        let dataDir = instanceDir.appendingPathComponent("data").path
        XCTAssertEqual(plan.arguments, ["--user-data-dir=\(dataDir)"])
        XCTAssertEqual(plan.createDirectories, [dataDir])
        XCTAssertNil(plan.homeOverride)
    }

    func testVSCodeFamilyGetsExtensionsDirToo() throws {
        let app = try Fixtures.makeApp(
            named: "FakeCode", bundleID: "com.fake.code", in: tempDir,
            electron: true, productJSON: true
        )
        let plan = try plan(for: app)
        XCTAssertEqual(plan.mode, .dataDir)
        XCTAssertEqual(plan.arguments.count, 2)
        XCTAssertTrue(plan.arguments[0].hasPrefix("--user-data-dir="))
        XCTAssertTrue(plan.arguments[1].hasPrefix("--extensions-dir="))
    }

    func testFirefoxGetsProfileFlags() throws {
        let app = try Fixtures.makeApp(
            named: "FakeFox", bundleID: "org.fake.firefox", in: tempDir, applicationIni: true
        )
        let plan = try plan(for: app)
        XCTAssertEqual(plan.mode, .dataDir)
        XCTAssertEqual(plan.arguments.first, "--no-remote")
        XCTAssertEqual(plan.arguments[1], "--profile")
        XCTAssertTrue(plan.arguments[2].hasSuffix("/profile"))
    }

    func testNativeAppFallsBackToHomeOverride() throws {
        let app = try Fixtures.makeApp(named: "FakeNative", bundleID: "com.fake.native", in: tempDir)
        let plan = try plan(for: app)
        XCTAssertEqual(plan.mode, .home)
        XCTAssertTrue(plan.arguments.isEmpty)
        XCTAssertEqual(plan.homeOverride, instanceDir.appendingPathComponent("home").path)
        XCTAssertEqual(plan.homeSymlinks, Presets.defaultSharedItems)
    }

    func testForcedLaunchOnlyHasNoIsolation() throws {
        let app = try Fixtures.makeApp(named: "FakeSlack2", bundleID: "com.fake.slack2", in: tempDir, electron: true)
        let plan = try plan(for: app, requested: .launchOnly)
        XCTAssertEqual(plan.mode, .launchOnly)
        XCTAssertTrue(plan.arguments.isEmpty)
        XCTAssertNil(plan.homeOverride)
        XCTAssertTrue(plan.createDirectories.isEmpty)
    }

    func testForcedDataDirOnNativeAppUsesGenericFlagWithWarning() throws {
        let app = try Fixtures.makeApp(named: "FakeNative2", bundleID: "com.fake.native2", in: tempDir)
        let plan = try plan(for: app, requested: .dataDir)
        XCTAssertEqual(plan.mode, .dataDir)
        XCTAssertEqual(plan.preset(), "generic-data-dir")
        XCTAssertTrue(plan.arguments.first?.hasPrefix("--user-data-dir=") ?? false)
        XCTAssertTrue(plan.notes.contains { $0.contains("No app-aware preset") })
    }

    func testForcedHomeRespectsSharedItems() throws {
        let app = try Fixtures.makeApp(named: "FakeSlack3", bundleID: "com.fake.slack3", in: tempDir, electron: true)
        let plan = try plan(for: app, requested: .home, sharedItems: ["Downloads"])
        XCTAssertEqual(plan.mode, .home)
        XCTAssertEqual(plan.homeSymlinks, ["Downloads"])
    }

    // MARK: App overrides (apps that ignore data-dir flags)

    func testCodexOverrideUsesEnvRecipe() throws {
        // Codex is Electron but pins userData in code (app.setPath) — flags do
        // nothing. Auto must apply its env-var recipe instead.
        let app = try Fixtures.makeApp(
            named: "FakeCodex", bundleID: "com.openai.codex", in: tempDir, electron: true
        )
        let plan = try plan(for: app)
        XCTAssertEqual(plan.mode, .dataDir)
        XCTAssertEqual(plan.presetID, "com.openai.codex")
        XCTAssertTrue(plan.arguments.isEmpty, "flags are useless for Codex")
        XCTAssertNil(plan.homeOverride)
        XCTAssertEqual(
            plan.environment["CODEX_ELECTRON_USER_DATA_PATH"],
            instanceDir.appendingPathComponent("data").path
        )
        XCTAssertEqual(
            plan.environment["CODEX_HOME"],
            instanceDir.appendingPathComponent("codex-home").path
        )
        XCTAssertEqual(Set(plan.createDirectories), Set(plan.environment.values))
        XCTAssertTrue(plan.notes.contains { $0.contains("CODEX_ELECTRON_USER_DATA_PATH") }, "\(plan.notes)")
    }

    func testForcedDataDirOnRecipeAppStillUsesRecipe() throws {
        // Data-dir mode means the app's recipe when it has one — a generic
        // flag would be ignored (Codex) and silently share data.
        let app = try Fixtures.makeApp(
            named: "FakeCodex2", bundleID: "com.openai.codex.beta", in: tempDir, electron: true
        )
        let plan = try plan(for: app, requested: .dataDir)
        XCTAssertEqual(plan.mode, .dataDir)
        XCTAssertEqual(plan.presetID, "com.openai.codex")
        XCTAssertNotNil(plan.environment["CODEX_ELECTRON_USER_DATA_PATH"])
        XCTAssertTrue(plan.arguments.isEmpty)
    }

    func testClaudeRecipeSetsUserDataDirBothWays() throws {
        let app = try Fixtures.makeApp(
            named: "FakeClaude", bundleID: "com.anthropic.claudefordesktop", in: tempDir, electron: true
        )
        let plan = try plan(for: app)
        let dataDir = instanceDir.appendingPathComponent("data").path
        XCTAssertEqual(plan.presetID, "com.anthropic.claudefordesktop")
        XCTAssertEqual(plan.arguments, ["--user-data-dir=\(dataDir)"])
        XCTAssertEqual(plan.environment["CLAUDE_USER_DATA_DIR"], dataDir)
        // Claude Code config stays shared unless the option is turned on.
        XCTAssertNil(plan.environment["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(plan.availableOptions.map(\.id), ["separate-claude-code"])
        XCTAssertEqual(plan.enabledOptions, [])
    }

    func testRecipeOptionAddsIsolation() throws {
        let app = try Fixtures.makeApp(
            named: "FakeClaude2", bundleID: "com.anthropic.claudefordesktop", in: tempDir, electron: true
        )
        let info = try AppInspector.inspect(app)
        let plan = Presets.plan(
            for: info, requested: .auto, instanceDir: instanceDir,
            sharedItems: [], enabledOptions: ["separate-claude-code"]
        )
        let configDir = instanceDir.appendingPathComponent("claude-code").path
        XCTAssertEqual(plan.environment["CLAUDE_CONFIG_DIR"], configDir)
        XCTAssertTrue(plan.createDirectories.contains(configDir))
        XCTAssertEqual(plan.enabledOptions, ["separate-claude-code"])
    }

    func testDotfileNoteFiresOnlyWhenDotfileExists() throws {
        let fakeHome = tempDir.appendingPathComponent("fake-home")
        try FileManager.default.createDirectory(
            at: fakeHome.appendingPathComponent(".fakeapp"),
            withIntermediateDirectories: true
        )
        let hit = Presets.dotfileNote(appName: "FakeApp", home: fakeHome)
        XCTAssertNotNil(hit)
        XCTAssertTrue(hit!.contains("~/.fakeapp"))
        XCTAssertNil(Presets.dotfileNote(appName: "NoSuchApp", home: fakeHome))
    }
}

private extension IsolationPlan {
    func preset() -> String? { presetID }
}
