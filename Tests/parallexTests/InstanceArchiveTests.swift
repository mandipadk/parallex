import XCTest
@testable import ParallexCore

final class InstanceArchiveTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("archive")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
        setenv("PARALLEX_LAUNCHER", Fixtures.launcherBinary.path, 1)
        setenv("PARALLEX_HOME_LIBRARY", Fixtures.homeLibrary.path, 1)
        outDir = tempDir.appendingPathComponent("apps", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    /// Fixture apps aren't registered with Launch Services; find them by ID.
    var apps: [String: URL] = [:]
    func locate(_ bundleID: String) -> URL? { apps[bundleID] }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        unsetenv("PARALLEX_LAUNCHER")
        unsetenv("PARALLEX_HOME_LIBRARY")
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRoundTripKeepsSettingsAndData() throws {
        let target = try Fixtures.makeApp(named: "Roundy", bundleID: "com.fake.roundy", in: tempDir, electron: true)
        apps["com.fake.roundy"] = target
        var request = CreateRequest(appReference: target.path, name: "Roundy Work", outputDirectory: outDir)
        request.badgeText = "R"
        let original = try InstanceCreator.create(request, builderOptions: options).manifest
        let data = Paths.instanceDir(slug: original.slug).appendingPathComponent("data/Local State")
        try FileManager.default.createDirectory(at: data.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("signed in".utf8).write(to: data)

        let file = tempDir.appendingPathComponent("Roundy Work.parallex")
        try InstanceArchive.export(original, to: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        // Importing next to the original gets a free name and its own folder.
        let imported = try InstanceArchive.import(from: file, outputDirectory: outDir, builderOptions: options, locateApp: locate).manifest
        XCTAssertEqual(imported.name, "Roundy Work 2")
        XCTAssertNotEqual(imported.slug, original.slug)
        XCTAssertEqual(imported.settings?.badgeText, "R")
        let importedData = Paths.instanceDir(slug: imported.slug).appendingPathComponent("data/Local State")
        XCTAssertEqual(try String(contentsOf: importedData, encoding: .utf8), "signed in")
        XCTAssertTrue(imported.arguments.allSatisfy { !$0.contains("/instances/\(original.slug)/") },
                      "paths point at the imported instance: \(imported.arguments)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.wrapperPath))
        XCTAssertTrue(InstanceStatus.check(imported).problems.isEmpty)
    }

    func testImportingAnOwnIdentityCopyRebuildsItHere() throws {
        let target = try Fixtures.makeHomeReportingApp(named: "Movable", bundleID: "com.fake.movable", in: tempDir)
        apps["com.fake.movable"] = target
        var request = CreateRequest(appReference: target.path, name: "Movable", outputDirectory: outDir)
        request.cloneApp = true
        let original = try InstanceCreator.create(request, builderOptions: options).manifest
        let file = tempDir.appendingPathComponent("m.parallex")
        try InstanceArchive.export(original, to: file)
        _ = try InstanceRemover.remove(original, keepData: false)

        let imported = try InstanceArchive.import(from: file, outputDirectory: outDir, builderOptions: options, locateApp: locate).manifest
        XCTAssertEqual(imported.name, "Movable", "the name is free again")
        XCTAssertEqual(imported.clone?.bundleIdentifier, "com.parallex.instance.\(imported.slug)")
        XCTAssertEqual(imported.redirectedHome, Paths.instanceDir(slug: imported.slug).appendingPathComponent("home").path)
        XCTAssertTrue(InstanceStatus.check(imported).problems.isEmpty, "\(InstanceStatus.check(imported).problems)")
        // Its data was encrypted with its own key: restoring it here finds
        // that key again.
        XCTAssertEqual(imported.keychainSuffix, original.keychainSuffix)
    }

    /// A file's keychain name is only taken when it's one Parallex makes.
    func testOnlyParallexKeychainNamesAreImported() {
        XCTAssertTrue(KeychainNames.isValidSuffix(" (Parallex movable-2)"))
        for bad in ["", " (Parallex )", "(Parallex x)", " (Parallex x) Safe Storage", " (Parallex a/b)",
                    " (Parallex \(String(repeating: "x", count: 120)))", " (Parallex ümlaut)"] {
            XCTAssertFalse(KeychainNames.isValidSuffix(bad), bad)
        }
    }

    func testRejectsFilesThatArentInstances() throws {
        let junk = tempDir.appendingPathComponent("junk.parallex")
        try Data("not a zip".utf8).write(to: junk)
        XCTAssertThrowsError(try InstanceArchive.import(from: junk, outputDirectory: outDir, builderOptions: options, locateApp: locate))
        XCTAssertTrue(InstanceStore.loadAll().isEmpty)
    }

    func testInstancePathIsFoundByWholeSlug() {
        var manifest = try! InstanceCreator.create(
            CreateRequest(appReference: Fixtures.makeApp(named: "P", bundleID: "com.fake.p", in: tempDir, electron: true).path,
                          name: "foo", outputDirectory: outDir), builderOptions: options).manifest
        manifest.arguments = ["--user-data-dir=/Volumes/Old Mac/Library/Application Support/Parallex/instances/foo-2/data",
                              "--user-data-dir=/Volumes/Old Mac/Library/Application Support/Parallex/instances/foo/data"]
        manifest.environment = [:]
        XCTAssertEqual(InstanceArchive.inferredInstancePath(of: manifest),
                       "/Volumes/Old Mac/Library/Application Support/Parallex/instances/foo")
    }

    func testImportTrustsNothingThatRunsCode() throws {
        let target = try Fixtures.makeApp(named: "Trusty", bundleID: "com.fake.trusty", in: tempDir, electron: true)
        apps["com.fake.trusty"] = target
        var request = CreateRequest(appReference: target.path, name: "Trusty", outputDirectory: outDir)
        request.environment = ["ELECTRON_RUN_AS_NODE": "1", "THEME": "dark"]
        request.extraArguments = ["--inspect=9229"]
        let original = try InstanceCreator.create(request, builderOptions: options).manifest
        // An escaping link planted in the data.
        let data = Paths.instanceDir(slug: original.slug).appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: data.appendingPathComponent("escape").path, withDestinationPath: "../../../../../..")
        let file = tempDir.appendingPathComponent("t.parallex")
        try InstanceArchive.export(original, to: file)

        let plain = try InstanceArchive.import(from: file, outputDirectory: outDir, builderOptions: options, locateApp: locate)
        XCTAssertEqual(plain.manifest.settings?.extraEnvironment, [:])
        XCTAssertEqual(plain.manifest.settings?.extraArguments, [])
        XCTAssertFalse(plain.warnings.isEmpty, "says what was left out")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(
            atPath: Paths.instanceDir(slug: plain.manifest.slug).appendingPathComponent("data/escape").path))

        let kept = try InstanceArchive.import(from: file, keepExtras: true, outputDirectory: outDir, builderOptions: options, locateApp: locate)
        XCTAssertEqual(kept.manifest.settings?.extraEnvironment, ["THEME": "dark"], "code-loading variables never come in")
    }

    func testExportIntoAFolderWritesInsideIt() throws {
        let target = try Fixtures.makeApp(named: "Folder", bundleID: "com.fake.folder", in: tempDir, electron: true)
        apps["com.fake.folder"] = target
        let manifest = try InstanceCreator.create(
            CreateRequest(appReference: target.path, name: "Folder Test", outputDirectory: outDir), builderOptions: options
        ).manifest
        let backups = tempDir.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: backups.appendingPathComponent("other.txt"))
        let written = try InstanceArchive.export(manifest, to: backups)
        XCTAssertEqual(written.lastPathComponent, "Folder Test.parallex")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backups.appendingPathComponent("other.txt").path), "the folder is untouched")
    }

    func testImportRejectsNamesThatArentFileNames() throws {
        let target = try Fixtures.makeApp(named: "Named", bundleID: "com.fake.named", in: tempDir, electron: true)
        apps["com.fake.named"] = target
        let manifest = try InstanceCreator.create(
            CreateRequest(appReference: target.path, name: "Named", outputDirectory: outDir), builderOptions: options
        ).manifest
        let file = tempDir.appendingPathComponent("n.parallex")
        try InstanceArchive.export(manifest, to: file)
        XCTAssertThrowsError(try InstanceArchive.import(from: file, name: "../../Evil", outputDirectory: outDir, builderOptions: options, locateApp: locate))
    }
}
