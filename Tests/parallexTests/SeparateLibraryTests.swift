import XCTest
@testable import ParallexCore
import ParallexKit

/// Own-identity copies of apps that aren't sandboxed keep their own
/// ~/Library: the copy loads the home-redirect library, and the app sees the
/// instance's home wherever macOS resolves "home" from the user account.
final class SeparateLibraryTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("library")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
        setenv("PARALLEX_LAUNCHER", Fixtures.launcherBinary.path, 1)
        setenv("PARALLEX_HOME_LIBRARY", Fixtures.homeLibrary.path, 1)
        outDir = tempDir.appendingPathComponent("apps", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        unsetenv("PARALLEX_LAUNCHER")
        unsetenv("PARALLEX_HOME_LIBRARY")
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Run a built instance through its launcher and read what the app saw.
    private func run(_ app: URL) throws -> [String] {
        let out = tempDir.appendingPathComponent("report-\(UUID().uuidString).txt")
        let process = Process()
        process.executableURL = app.appendingPathComponent("Contents/MacOS/parallex-launcher")
        var environment = ProcessInfo.processInfo.environment
        environment["FIXTURE_OUT"] = out.path
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: out.path) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return try String(contentsOf: out, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    func testCopyOfNativeAppSeesTheInstanceHome() throws {
        let target = try Fixtures.makeHomeReportingApp(named: "Homey", bundleID: "com.fake.homey", in: tempDir)
        var request = CreateRequest(appReference: target.path, name: "Homey Work", outputDirectory: outDir)
        request.cloneApp = true
        let result = try InstanceCreator.create(request, builderOptions: options)

        let home = Paths.instanceDir(slug: "homey-work").appendingPathComponent("home").path
        XCTAssertEqual(result.manifest.redirectedHome, home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Paths.homeLibrary.path), "the library is installed")
        let config = try XCTUnwrap(NSDictionary(contentsOf: result.wrapperURL.appendingPathComponent("Contents/Info.plist"))?[ParallexConfig.rootKey] as? [String: Any])
        XCTAssertEqual(config[ParallexConfig.Key.redirectLibrary] as? String, Paths.homeLibrary.path)

        let report = try run(result.wrapperURL)
        XCTAssertEqual(report[0], home, "NSHomeDirectory is the instance's home")
        XCTAssertEqual(report[1], home + "/Library/Application Support")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/Library/Application Support/Homey"),
                      "what the app writes lands in the instance")
        let realSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Homey")
        XCTAssertFalse(FileManager.default.fileExists(atPath: realSupport.path), "nothing in the real Library")
        // Shared folders are still reachable through the instance home.
        let documents = URL(fileURLWithPath: home).appendingPathComponent("Documents")
        XCTAssertEqual(try? FileManager.default.destinationOfSymbolicLink(atPath: documents.path),
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents").path)
    }

    func testTurningSeparationOffUsesTheRealLibrary() throws {
        let target = try Fixtures.makeHomeReportingApp(named: "Plain", bundleID: "com.fake.plain", in: tempDir)
        var request = CreateRequest(appReference: target.path, name: "Plain Work", outputDirectory: outDir)
        request.cloneApp = true
        let created = try InstanceCreator.create(request, builderOptions: options)
        var settings = created.manifest.effectiveSettings
        settings.separateLibrary = false
        let rebuilt = try InstanceCreator.update(created.manifest, InstanceUpdate(settings: settings), builderOptions: options)

        XCTAssertNil(rebuilt.manifest.redirectedHome)
        let config = try XCTUnwrap(NSDictionary(contentsOf: rebuilt.wrapperURL.appendingPathComponent("Contents/Info.plist"))?[ParallexConfig.rootKey] as? [String: Any])
        XCTAssertNil(config[ParallexConfig.Key.redirectHome])
        let report = try run(rebuilt.wrapperURL)
        XCTAssertEqual(report[0], FileManager.default.homeDirectoryForCurrentUser.path)
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Plain"))
    }

    func testCopiesMadeBeforeSeparationExistedKeepTheirLibrary() throws {
        let target = try Fixtures.makeHomeReportingApp(named: "Oldie", bundleID: "com.fake.oldie", in: tempDir)
        var request = CreateRequest(appReference: target.path, name: "Oldie Work", outputDirectory: outDir)
        request.cloneApp = true
        var manifest = try InstanceCreator.create(request, builderOptions: options).manifest
        // As a 0.8 instance would have been recorded.
        manifest.parallexVersion = "0.8.0"
        manifest.redirectedHome = nil
        manifest.settings?.separateLibrary = nil
        XCTAssertEqual(manifest.effectiveSettings.separateLibrary, false, "a routine rebuild must not move its data")
        let rebuilt = try InstanceCreator.update(manifest, InstanceUpdate(), builderOptions: options)
        XCTAssertNil(rebuilt.manifest.redirectedHome)
    }

    func testWrappersAndSandboxedCopiesAreUnaffected() throws {
        let target = try Fixtures.makeHomeReportingApp(named: "Wrap", bundleID: "com.fake.wrap", in: tempDir)
        let result = try InstanceCreator.create(
            CreateRequest(appReference: target.path, name: "Wrap Work", outputDirectory: outDir), builderOptions: options
        )
        XCTAssertNil(result.manifest.redirectedHome, "a plain wrapper can't load the library (hardened apps)")
    }

    func testRemovalTakesTheCopysPreferencesAlong() throws {
        let target = try Fixtures.makeHomeReportingApp(named: "Prefy", bundleID: "com.fake.prefy", in: tempDir)
        var request = CreateRequest(appReference: target.path, name: "Prefy Test \(UUID().uuidString.prefix(6))", outputDirectory: outDir)
        request.cloneApp = true
        let manifest = try InstanceCreator.create(request, builderOptions: options).manifest
        let domain = try XCTUnwrap(manifest.clone?.bundleIdentifier)
        _ = try Shell.run("/usr/bin/defaults", ["write", domain, "lastVault", "Work"])
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(domain).plist")
        defer { Shell.runAllowingFailure("/usr/bin/defaults", ["delete", domain]); try? FileManager.default.removeItem(at: file) }

        let destination = tempDir.appendingPathComponent("instance-copy", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        InstanceRemover.moveSystemState(of: manifest, into: destination)

        let saved = try XCTUnwrap(NSDictionary(contentsOf: destination.appendingPathComponent("preferences.plist")))
        XCTAssertEqual(saved["lastVault"] as? String, "Work", "preferences travel with the instance's data")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing left in ~/Library/Preferences")
    }

    func testServicesAndHelpersInsideTheCopyGetTheRedirectToo() throws {
        let target = try Fixtures.makeHomeReportingApp(named: "Servy", bundleID: "com.fake.servy", in: tempDir)
        // An XPC service, as macOS launches it (not inheriting the launcher's environment).
        let service = target.appendingPathComponent("Contents/XPCServices/Worker.xpc/Contents")
        try FileManager.default.createDirectory(at: service.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: service.appendingPathComponent("MacOS/Worker").path)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.fake.servy.worker", "CFBundleExecutable": "Worker", "CFBundlePackageType": "XPC!",
            "XPCService": ["ServiceType": "Application"],
        ] as [String: Any], format: .xml, options: 0).write(to: service.appendingPathComponent("Info.plist"))

        var request = CreateRequest(appReference: target.path, name: "Servy Work", outputDirectory: outDir)
        request.cloneApp = true
        let result = try InstanceCreator.create(request, builderOptions: options)

        let plist = try XCTUnwrap(NSDictionary(contentsOf: result.wrapperURL
            .appendingPathComponent("Contents/XPCServices/Worker.xpc/Contents/Info.plist")) as? [String: Any])
        let variables = try XCTUnwrap((plist["XPCService"] as? [String: Any])?["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(variables["PARALLEX_HOME_REDIRECT"], result.manifest.redirectedHome)
        XCTAssertEqual(variables["PARALLEX_HOME_SCOPE"], result.wrapperURL.standardizedFileURL.path)
        XCTAssertEqual(variables["DYLD_INSERT_LIBRARIES"], Paths.homeLibrary.path)
        XCTAssertEqual((plist["XPCService"] as? [String: Any])?["ServiceType"] as? String, "Application", "the rest is kept")
        // Still a validly signed copy.
        XCTAssertNoThrow(try Shell.run("/usr/bin/codesign", ["--verify", "--deep", result.wrapperURL.path]))
    }

    func testAMovedCopyRefusesToRunUnredirected() throws {
        let target = try Fixtures.makeHomeReportingApp(named: "Movy", bundleID: "com.fake.movy", in: tempDir)
        var request = CreateRequest(appReference: target.path, name: "Movy Work", outputDirectory: outDir)
        request.cloneApp = true
        let result = try InstanceCreator.create(request, builderOptions: options)
        let moved = tempDir.appendingPathComponent("Elsewhere.app")
        try FileManager.default.moveItem(at: result.wrapperURL, to: moved)

        let out = tempDir.appendingPathComponent("moved.txt")
        let process = Process()
        process.executableURL = moved.appendingPathComponent("Contents/MacOS/parallex-launcher")
        var environment = ProcessInfo.processInfo.environment
        environment["FIXTURE_OUT"] = out.path
        environment["PARALLEX_LAUNCHER_NO_UI"] = "1"
        process.environment = environment
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "the app never ran with the real Library")
    }

    func testToolsStartedByTheCopyDontInheritTheLibrary() throws {
        // A process outside the copy's bundle that inherits the variables
        // takes them out of its environment, so its children are clean.
        let out = tempDir.appendingPathComponent("env.txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // /usr/bin/env is protected (dyld ignores the insert), so run a
        // copy of it from outside the scope instead.
        let tool = tempDir.appendingPathComponent("tool")
        try FileManager.default.copyItem(atPath: "/usr/bin/env", toPath: tool.path)
        _ = try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", tool.path])
        process.executableURL = tool
        process.arguments = ["/usr/bin/env"]
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_INSERT_LIBRARIES"] = Fixtures.homeLibrary.path
        environment["PARALLEX_HOME_REDIRECT"] = tempDir.path
        environment["PARALLEX_HOME_SCOPE"] = "/Applications/Somewhere Else.app"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let printed = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertFalse(printed.contains("PARALLEX_HOME_REDIRECT"), printed)
        XCTAssertFalse(printed.contains("libparallexhome"), printed)
        _ = out
    }

    func testRemovingACopyLeavesNoPreferencesBehind() throws {
        let target = try Fixtures.makeHomeReportingApp(named: "Gone", bundleID: "com.fake.gone", in: tempDir)
        var request = CreateRequest(appReference: target.path, name: "Gone Test \(UUID().uuidString.prefix(6))", outputDirectory: outDir)
        request.cloneApp = true
        let manifest = try InstanceCreator.create(request, builderOptions: options).manifest
        let domain = try XCTUnwrap(manifest.clone?.bundleIdentifier)
        _ = try Shell.run("/usr/bin/defaults", ["write", domain, "k", "v"])
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(domain).plist")
        defer { Shell.runAllowingFailure("/usr/bin/defaults", ["delete", domain]); try? FileManager.default.removeItem(at: file) }

        _ = try InstanceRemover.remove(manifest, keepData: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
