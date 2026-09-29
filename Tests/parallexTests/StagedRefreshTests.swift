import XCTest
@testable import ParallexCore
import ParallexKit

/// A copy in use when its app updates gets its refresh built beside it,
/// which takes its place the moment it quits (or when it's next opened).
final class StagedRefreshTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("staged")
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

    /// An app whose executable is `sleep`, so its copy can be kept running.
    private func makeCopy(_ name: String, seconds: String) throws -> (target: URL, result: CreateResult) {
        let target = try Fixtures.makeApp(
            named: name, bundleID: "com.fake.\(name.lowercased())", in: tempDir,
            extraInfoKeys: ["CFBundleShortVersionString": "1.0"]
        )
        // A real program of its own (a copy of /bin/sleep, Apple's, won't
        // run re-signed): sleeps for as many seconds as it's told.
        let source = tempDir.appendingPathComponent("\(name).c")
        try Data("#include <stdlib.h>\n#include <unistd.h>\nint main(int c, char **v) { sleep(c > 1 ? atoi(v[1]) : 0); return 0; }\n".utf8)
            .write(to: source)
        let executable = target.appendingPathComponent("Contents/MacOS/\(name)")
        try FileManager.default.removeItem(at: executable)
        try Shell.run("/usr/bin/clang", [source.path, "-o", executable.path])
        var request = CreateRequest(appReference: target.path, name: "\(name) Work", outputDirectory: outDir)
        request.cloneApp = true
        request.extraArguments = [seconds]
        return (target, try InstanceCreator.create(request, builderOptions: options))
    }

    private func updateOriginal(_ target: URL, to version: String) throws {
        let url = target.appendingPathComponent("Contents/Info.plist")
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        plist["CFBundleShortVersionString"] = version
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    private func version(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    private func start(_ copy: URL) throws -> Process {
        let process = Process()
        process.executableURL = copy.appendingPathComponent("Contents/MacOS/parallex-launcher")
        try process.run()
        return process
    }

    func testARunningCopysRefreshWaitsThenTakesOverWhenItQuits() throws {
        let (target, result) = try makeCopy("Busy", seconds: "30")
        let running = try start(result.wrapperURL)
        defer { running.terminate() }
        for _ in 0..<100 where !Running.isRunning(result.manifest) { usleep(50_000) }
        XCTAssertTrue(Running.isRunning(result.manifest))

        try updateOriginal(target, to: "2.0")
        XCTAssertEqual(InstanceStatus.check(result.manifest).problems, [.cloneOutdated(copyOf: "1.0 (?)", original: "2.0 (?)")])
        XCTAssertThrowsError(try InstanceCreator.update(result.manifest, builderOptions: options), "a running copy isn't rebuilt")

        try InstanceCreator.stageRefresh(result.manifest, builderOptions: options)
        XCTAssertTrue(InstanceCreator.stagedRefreshIsCurrent(for: result.manifest))
        XCTAssertEqual(version(of: result.wrapperURL), "1.0", "the running copy is left alone")
        XCTAssertNil(try InstanceCreator.installStagedRefresh(result.manifest, builderOptions: options),
                     "nothing takes its place while it runs")

        running.terminate()
        running.waitUntilExit()
        let installed = try XCTUnwrap(try InstanceCreator.installStagedRefresh(result.manifest, builderOptions: options))
        XCTAssertEqual(installed.clone?.sourceVersion, "2.0 (?)")
        XCTAssertEqual(version(of: result.wrapperURL), "2.0")
        XCTAssertEqual(InstanceStore.load(slug: result.manifest.slug)?.clone?.sourceVersion, "2.0 (?)")
        XCTAssertTrue(InstanceStatus.check(installed).problems.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.stagingDir(slug: result.manifest.slug).path),
                       "the replaced copy went to the Trash")
        XCTAssertNoThrow(try Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", result.wrapperURL.path]))
    }

    /// Opened before Parallex could put the refresh in place: the copy's
    /// launcher does it, and starts over from the refreshed copy.
    func testTheCopysLauncherInstallsAWaitingRefresh() throws {
        let (target, result) = try makeCopy("Late", seconds: "0")
        try updateOriginal(target, to: "2.0")
        try InstanceCreator.stageRefresh(result.manifest, builderOptions: options)

        let process = try start(result.wrapperURL)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(version(of: result.wrapperURL), "2.0")
        XCTAssertEqual(InstanceStore.load(slug: result.manifest.slug)?.clone?.sourceVersion, "2.0 (?)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.stagedCopy(slug: result.manifest.slug).path))
        let record = try XCTUnwrap(PidFileRecord(parsing: String(contentsOf: Paths.pidFile(slug: result.manifest.slug), encoding: .utf8)))
        XCTAssertEqual(record.executablePath, result.wrapperURL.appendingPathComponent("Contents/MacOS/Late").path,
                       "the refreshed copy is the one that ran")
    }

    func testARebuildDiscardsAWaitingRefresh() throws {
        let (target, result) = try makeCopy("Edit", seconds: "0")
        try updateOriginal(target, to: "2.0")
        try InstanceCreator.stageRefresh(result.manifest, builderOptions: options)
        XCTAssertNotNil(InstanceCreator.stagedRefresh(of: result.manifest))
        _ = try InstanceCreator.update(result.manifest, builderOptions: options)
        XCTAssertNil(InstanceCreator.stagedRefresh(of: result.manifest))
    }
}
