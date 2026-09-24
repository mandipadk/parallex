import XCTest
@testable import ParallexCore
@testable import ParallexKit

/// Sharing part of a settings file with the original (Claude's MCP servers).
final class SettingsSyncTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("settings-sync")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
        setenv("PARALLEX_LAUNCHER", Fixtures.launcherBinary.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        unsetenv("PARALLEX_LAUNCHER")
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ json: String, _ name: String) throws -> String {
        let url = tempDir.appendingPathComponent(name)
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func read(_ path: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
    }

    func testSharesOnlyTheChosenKeys() throws {
        let original = try write(#"{"mcpServers": {"files": {"command": "npx"}}, "preferences": {"theme": "dark"}}"#, "original.json")
        let instance = try write(#"{"preferences": {"theme": "light"}, "coworkUserFilesPath": "/x"}"#, "instance.json")
        let item = SettingsSync.Item(from: original, to: instance, keys: ["mcpServers"])

        XCTAssertTrue(try SettingsSync.apply(item))
        let synced = try read(instance)
        XCTAssertEqual((synced["mcpServers"] as? [String: Any])?.keys.sorted(), ["files"])
        XCTAssertEqual((synced["preferences"] as? [String: Any])?["theme"] as? String, "light", "its own preferences stay")
        XCTAssertEqual(synced["coworkUserFilesPath"] as? String, "/x")
        XCTAssertFalse(try SettingsSync.apply(item), "already in step: nothing written")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: tempDir.path).contains { $0.contains(SettingsSync.backupSuffix) }, "nothing of its own was replaced")
    }

    /// Whatever was changed in the instance is kept in a dated backup
    /// before it's replaced, every time, not only the first; and the
    /// original having none removes them.
    func testChangesMadeInTheInstanceAreBackedUp() throws {
        let original = try write(#"{"mcpServers": {"a": {}}}"#, "original.json")
        let instance = try write(#"{"mcpServers": {"mine": {"command": "x"}}}"#, "instance.json")
        let item = SettingsSync.Item(from: original, to: instance, keys: ["mcpServers"])
        XCTAssertTrue(try SettingsSync.apply(item, now: Date(timeIntervalSince1970: 1_790_000_000)))
        func backups() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: tempDir.path).filter { $0.contains(SettingsSync.backupSuffix) }
        }
        XCTAssertEqual(try backups().count, 1, "its own servers, kept")

        // The original changes: nothing of the instance's own is lost, so no backup.
        _ = try write(#"{"mcpServers": {"b": {}}}"#, "original.json")
        XCTAssertTrue(try SettingsSync.apply(item, now: Date(timeIntervalSince1970: 1_790_000_100)))
        XCTAssertEqual(try backups().count, 1)

        // Edited in the instance again: kept again before it's replaced.
        _ = try write(#"{"mcpServers": {"b": {}, "added-here": {}}}"#, "instance.json")
        XCTAssertTrue(try SettingsSync.apply(item, now: Date(timeIntervalSince1970: 1_790_000_200)))
        XCTAssertEqual(try backups().count, 2)

        _ = try write(#"{"preferences": {}}"#, "original.json")
        XCTAssertTrue(try SettingsSync.apply(item))
        XCTAssertNil(try read(instance)["mcpServers"], "the original says there are none")
    }

    /// A missing or empty original (not set up, or caught mid-save)
    /// changes nothing; a settings file that's a link is written through.
    func testNoOriginalMeansNoChange() throws {
        let instance = try write(#"{"mcpServers": {"mine": {}}}"#, "instance.json")
        XCTAssertFalse(try SettingsSync.apply(SettingsSync.Item(from: tempDir.appendingPathComponent("none.json").path, to: instance, keys: ["mcpServers"])))
        let empty = try write("", "empty.json")
        XCTAssertFalse(try SettingsSync.apply(SettingsSync.Item(from: empty, to: instance, keys: ["mcpServers"])))
        XCTAssertNotNil(try read(instance)["mcpServers"])

        let original = try write(#"{"mcpServers": {"a": {}}}"#, "original.json")
        let link = tempDir.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: instance))
        XCTAssertTrue(try SettingsSync.apply(SettingsSync.Item(from: original, to: link.path, keys: ["mcpServers"])))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), "still a link")
        XCTAssertNotNil((try read(instance)["mcpServers"] as? [String: Any])?["a"])
    }

    func testMissingAndBrokenFiles() throws {
        let fresh = tempDir.appendingPathComponent("data/fresh.json").path
        let bare = try write(#"{"preferences": {}}"#, "bare.json")
        XCTAssertFalse(try SettingsSync.apply(SettingsSync.Item(from: bare, to: fresh, keys: ["mcpServers"])), "nothing to share, nothing made")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh))

        let original = try write(#"{"mcpServers": {"a": {}}}"#, "original.json")
        XCTAssertTrue(try SettingsSync.apply(SettingsSync.Item(from: original, to: fresh, keys: ["mcpServers"])), "made, folder and all")
        XCTAssertNotNil(try read(fresh)["mcpServers"])

        let broken = try write("{ not json", "broken.json")
        XCTAssertThrowsError(try SettingsSync.apply(SettingsSync.Item(from: original, to: broken, keys: ["mcpServers"])))
        XCTAssertEqual(try String(contentsOfFile: broken, encoding: .utf8), "{ not json", "left alone")
    }

    /// Claude's "Share MCP servers" reaches the launcher, pointed at your
    /// Claude's config and the instance's own.
    func testClaudeOptionReachesTheLauncher() throws {
        let app = try Fixtures.makeApp(named: "Claude", bundleID: "com.anthropic.claudefordesktop", in: tempDir, electron: true)
        var request = CreateRequest(appReference: app.path, name: "Claude Two", outputDirectory: tempDir)
        request.enabledOptions = ["share-mcp-servers"]
        let result = try InstanceCreator.create(request, builderOptions: BundleBuilder.Options(registerWithLaunchServices: false))
        let plist = try XCTUnwrap(NSDictionary(contentsOf: result.wrapperURL.appendingPathComponent("Contents/Info.plist")))
        let config = try XCTUnwrap(plist[ParallexConfig.rootKey] as? [String: Any])
        let items = (config[ParallexConfig.Key.settingsSync] as? [Any] ?? []).compactMap(SettingsSync.Item.init(plist:))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.from, FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/Claude/claude_desktop_config.json")
        XCTAssertEqual(items.first?.to, Paths.instanceDir(slug: result.manifest.slug).path + "/data/claude_desktop_config.json")
        XCTAssertEqual(items.first?.keys, ["mcpServers"])

        request.name = "Claude Three"
        request.enabledOptions = []
        let plain = try InstanceCreator.create(request, builderOptions: BundleBuilder.Options(registerWithLaunchServices: false))
        let plainConfig = try XCTUnwrap(NSDictionary(contentsOf: plain.wrapperURL.appendingPathComponent("Contents/Info.plist"))?[ParallexConfig.rootKey] as? [String: Any])
        XCTAssertNil(plainConfig[ParallexConfig.Key.settingsSync], "off unless chosen")
    }
}
