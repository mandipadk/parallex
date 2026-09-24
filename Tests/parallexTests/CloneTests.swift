import XCTest
@testable import ParallexCore
import ParallexKit

/// Clone mode: the instance is a re-signed copy of the app with its own
/// bundle ID, whose main executable is the Parallex launcher.
final class CloneTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("clone")
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

    /// Fixtures mark Electron with an empty framework folder; a copy gets
    /// re-signed, which needs a real (if tiny) framework bundle there.
    private func makeSignableElectronApp(named name: String, bundleID: String, extraInfoKeys: [String: Any] = [:]) throws -> URL {
        let app = try Fixtures.makeApp(named: name, bundleID: bundleID, in: tempDir, electron: true, extraInfoKeys: extraInfoKeys)
        let fm = FileManager.default
        let framework = app.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        let versionA = framework.appendingPathComponent("Versions/A")
        try fm.createDirectory(at: versionA.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: versionA.appendingPathComponent("Electron Framework"))
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.github.Electron.framework",
            "CFBundleExecutable": "Electron Framework",
            "CFBundlePackageType": "FMWK",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: versionA.appendingPathComponent("Resources/Info.plist"))
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try fm.createSymbolicLink(
            atPath: framework.appendingPathComponent("Electron Framework").path,
            withDestinationPath: "Versions/Current/Electron Framework"
        )
        try fm.createSymbolicLink(
            atPath: framework.appendingPathComponent("Resources").path, withDestinationPath: "Versions/Current/Resources"
        )
        return app
    }

    private func info(_ app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testCloneHasOwnIdentityAndRunsThroughTheLauncher() throws {
        let target = try makeSignableElectronApp(
            named: "Cloney", bundleID: "com.fake.cloney", extraInfoKeys: ["CFBundleShortVersionString": "1.0"]
        )
        let witness = tempDir.appendingPathComponent("witness.txt")
        try Data("#!/bin/sh\nprintf '%s|%s' \"$1\" \"$PARALLEX_INSTANCE\" > \"\(witness.path)\"\n".utf8)
            .write(to: target.appendingPathComponent("Contents/MacOS/Cloney"))

        var request = CreateRequest(appReference: target.path, name: "Cloney Work", outputDirectory: outDir)
        request.cloneApp = true
        let result = try InstanceCreator.create(request, builderOptions: options)

        let copy = result.wrapperURL
        let plist = try info(copy)
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.parallex.instance.cloney-work")
        XCTAssertEqual(plist["CFBundleName"] as? String, "Cloney", "kept: apps find helpers by it")
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "Cloney Work")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "parallex-launcher")
        let config = try XCTUnwrap(plist[ParallexConfig.rootKey] as? [String: Any])
        XCTAssertNil(config[ParallexConfig.Key.targetApp], "a clone's launcher must not re-resolve its own bundle")
        let realBinary = copy.appendingPathComponent("Contents/MacOS/Cloney").path
        XCTAssertEqual(config[ParallexConfig.Key.targetBinary] as? String, realBinary)
        XCTAssertEqual(result.manifest.targetBinary, realBinary)
        XCTAssertEqual(result.manifest.clone?.bundleIdentifier, "com.parallex.instance.cloney-work")
        XCTAssertEqual(result.manifest.clone?.usesLauncher, true)
        XCTAssertTrue(BundleBuilder.isParallexWrapper(copy))
        XCTAssertNoThrow(try Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", copy.path]))

        // Running the copy's launcher execs the copy's own binary with the
        // isolation flags.
        let process = Process()
        process.executableURL = copy.appendingPathComponent("Contents/MacOS/parallex-launcher")
        var env = ProcessInfo.processInfo.environment
        env["PARALLEX_LAUNCHER_NO_UI"] = "1"
        process.environment = env
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let seen = try String(contentsOf: witness, encoding: .utf8)
        XCTAssertTrue(seen.hasPrefix("--user-data-dir="), seen)
        XCTAssertTrue(seen.hasSuffix("|cloney-work"), seen)
    }

    /// Finder metadata on an app (Zoom ships some on its bundle) makes
    /// codesign refuse ("detritus not allowed"); copies are made anyway.
    func testAppsWithFinderMetadataCanBeCopied() throws {
        let target = try makeSignableElectronApp(named: "Zoomy", bundleID: "com.fake.zoomy")
        try Shell.run("/usr/bin/xattr", ["-wx", "com.apple.FinderInfo", String(repeating: "0", count: 16) + "0400" + String(repeating: "0", count: 44), target.path])
        var request = CreateRequest(appReference: target.path, name: "Zoomy Work", outputDirectory: outDir)
        request.cloneApp = true
        let result = try InstanceCreator.create(request, builderOptions: options)
        XCTAssertNoThrow(try Shell.run("/usr/bin/codesign", ["--verify", "--deep", result.wrapperURL.path]))
        XCTAssertTrue(((try? Shell.run("/usr/bin/xattr", [target.path])) ?? "").contains("com.apple.FinderInfo"),
                      "the original is left as it was")
    }

    func testOriginalUpdateMarksCloneOutdated() throws {
        let target = try Fixtures.makeApp(
            named: "Versioned", bundleID: "com.fake.versioned", in: tempDir,
            extraInfoKeys: ["CFBundleShortVersionString": "1.0", "CFBundleVersion": "10"]
        )
        var request = CreateRequest(appReference: target.path, name: "Versioned Copy", outputDirectory: outDir)
        request.cloneApp = true
        let result = try InstanceCreator.create(request, builderOptions: options)
        XCTAssertTrue(InstanceStatus.check(result.manifest).problems.isEmpty)

        var plist = try info(target)
        plist["CFBundleShortVersionString"] = "2.0"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: target.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(
            InstanceStatus.check(result.manifest).problems,
            [.cloneOutdated(copyOf: "1.0 (10)", original: "2.0 (10)")]
        )
        // Repair refreshes the copy.
        let repaired = try InstanceCreator.update(result.manifest, builderOptions: options)
        XCTAssertEqual(repaired.manifest.clone?.sourceVersion, "2.0 (10)")
        XCTAssertTrue(InstanceStatus.check(repaired.manifest).problems.isEmpty)
    }

    func testTurningCloneOffGoesBackToAWrapper() throws {
        let target = try makeSignableElectronApp(named: "Toggle", bundleID: "com.fake.toggle")
        var request = CreateRequest(appReference: target.path, name: "Toggle Copy", outputDirectory: outDir)
        request.cloneApp = true
        let created = try InstanceCreator.create(request, builderOptions: options)
        var settings = created.manifest.effectiveSettings
        settings.cloneApp = nil
        let plain = try InstanceCreator.update(created.manifest, InstanceUpdate(settings: settings), builderOptions: options)
        XCTAssertNil(plain.manifest.clone)
        XCTAssertEqual(try info(plain.wrapperURL)["CFBundleExecutable"] as? String, "launcher")
        XCTAssertEqual(plain.manifest.targetBinary, target.appendingPathComponent("Contents/MacOS/Toggle").path)
    }

    func testCloningThroughASymlinkNeverTouchesTheOriginal() throws {
        let real = try makeSignableElectronApp(named: "Linked", bundleID: "com.fake.linked")
        let before = try Data(contentsOf: real.appendingPathComponent("Contents/Info.plist"))
        let link = tempDir.appendingPathComponent("links/Linked.app")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        var request = CreateRequest(appReference: link.path, name: "Linked Copy", outputDirectory: outDir)
        request.cloneApp = true
        let result = try InstanceCreator.create(request, builderOptions: options)

        XCTAssertEqual(try Data(contentsOf: real.appendingPathComponent("Contents/Info.plist")), before)
        XCTAssertFalse(BundleBuilder.isParallexWrapper(real))
        let values = try result.wrapperURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertNotEqual(values.isSymbolicLink, true, "the copy must be a real bundle")
        XCTAssertEqual(try info(result.wrapperURL)["CFBundleIdentifier"] as? String, "com.parallex.instance.linked-copy")
    }

    func testAppleAppsCantBeCloned() throws {
        let target = try Fixtures.makeApp(named: "FakeNotes", bundleID: "com.apple.FakeNotes", in: tempDir)
        var request = CreateRequest(appReference: target.path, name: "Notes Copy", outputDirectory: outDir)
        request.cloneApp = true
        XCTAssertThrowsError(try InstanceCreator.create(request, builderOptions: options)) { error in
            XCTAssertTrue("\(error)".contains("part of macOS"), "\(error)")
        }
    }

    func testRestrictedEntitlementsAreRecognized() {
        XCTAssertTrue(AppCloner.isRestricted("com.apple.developer.icloud-services"))
        XCTAssertTrue(AppCloner.isRestricted("keychain-access-groups"))
        XCTAssertTrue(AppCloner.isRestricted("com.apple.application-identifier"))
        XCTAssertFalse(AppCloner.isRestricted("com.apple.security.app-sandbox"))
        XCTAssertFalse(AppCloner.isRestricted("com.apple.security.device.camera"))
    }
}
