import XCTest
@testable import ParallexCore
import ParallexKit

/// A copy with its own Library records every file of yours (outside the
/// instance) that it opens, so its isolation check covers all of its life,
/// not only what it has open at the moment of checking.
final class AccessRecordTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)
    let realHome = FileManager.default.homeDirectoryForCurrentUser.path

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("record")
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

    /// An app that looks at your real ~/Library (reading only) and writes a
    /// file in what it sees as its own Application Support.
    private func makeCopy(named name: String) throws -> CreateResult {
        let app = try Fixtures.makeApp(named: name, bundleID: "com.fake.\(name.lowercased())", in: tempDir)
        let source = tempDir.appendingPathComponent("\(name).m")
        try Data("""
        #import <Foundation/Foundation.h>
        #include <fcntl.h>
        int main(void) {
            @autoreleasepool {
                int fd = open(getenv("FIXTURE_LOOK_AT"), O_RDONLY);
                if (fd >= 0) close(fd);
                NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
                [[NSFileManager defaultManager] createDirectoryAtPath:support withIntermediateDirectories:YES attributes:nil error:nil];
                [@"own" writeToFile:[support stringByAppendingPathComponent:@"own.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                [@"done" writeToFile:[NSString stringWithUTF8String:getenv("FIXTURE_OUT")] atomically:NO encoding:NSUTF8StringEncoding error:nil];
            }
            return 0;
        }
        """.utf8).write(to: source)
        let executable = app.appendingPathComponent("Contents/MacOS/\(name)")
        try? FileManager.default.removeItem(at: executable)
        try Shell.run("/usr/bin/clang", ["-fobjc-arc", "-framework", "Foundation", source.path, "-o", executable.path])
        var request = CreateRequest(appReference: app.path, name: "\(name) Work", outputDirectory: outDir)
        request.cloneApp = true
        return try InstanceCreator.create(request, builderOptions: options)
    }

    private func launch(_ copy: URL, lookingAt path: String) throws {
        let out = tempDir.appendingPathComponent("out-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = copy.appendingPathComponent("Contents/MacOS/parallex-launcher")
        var environment = ProcessInfo.processInfo.environment
        environment["FIXTURE_OUT"] = out.path
        environment["FIXTURE_LOOK_AT"] = path
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: out.path) { usleep(50_000) }
    }

    func testACopyRecordsWhatItOpensOfYoursAndNothingOfItsOwn() throws {
        let result = try makeCopy(named: "Nosy")
        let library = realHome + "/Library"
        try launch(result.wrapperURL, lookingAt: library)

        let entries = AccessRecord.entries(for: result.manifest)
        XCTAssertTrue(entries.contains { $0.path == library && $0.operation == "read" && $0.program == "Nosy" }, "\(entries)")
        XCTAssertFalse(entries.contains { $0.path.contains("own.txt") }, "its own Library isn't recorded")
        XCTAssertTrue(entries.allSatisfy { !$0.path.hasPrefix(Paths.instanceDir(slug: result.manifest.slug).path) })
        let report = try XCTUnwrap(IsolationCheck.recorded(result.manifest))
        XCTAssertTrue(report.isClean, "a look at ~/Library itself isn't the original's data")
        XCTAssertNotNil(report.recordedSince)
    }

    /// The recorder's notes are sorted like the snapshot's: the original's
    /// data folder is a leak, even with the copy not running.
    func testRecordedUseOfTheOriginalsDataIsALeak() throws {
        let result = try makeCopy(named: "Leaky")
        try launch(result.wrapperURL, lookingAt: realHome + "/Library")
        let log = Paths.instanceDir(slug: result.manifest.slug).appendingPathComponent("access.log")
        let handle = try FileHandle(forWritingTo: log)
        handle.seekToEndOfFile()
        let original = realHome + "/Library/Application Support/Leaky/Cookies"
        handle.write(Data("\(Int(Date().timeIntervalSince1970))\t4242\tLeaky\tread\t\(original)\n".utf8))
        try handle.close()

        let report = try XCTUnwrap(IsolationCheck.recorded(result.manifest))
        XCTAssertFalse(report.isClean)
        XCTAssertEqual(report.findings(in: .leak).map(\.path), [original])
    }

    func testTheRecordStaysWithItsInstance() throws {
        let result = try makeCopy(named: "Kept")
        try launch(result.wrapperURL, lookingAt: realHome + "/Library")
        XCTAssertTrue(AccessRecord.exists(for: result.manifest))
        let twin = try InstanceCreator.duplicate(result.manifest, includeData: true, builderOptions: options)
        XCTAssertFalse(AccessRecord.exists(for: twin.manifest), "a duplicate starts its own record")
    }
}
