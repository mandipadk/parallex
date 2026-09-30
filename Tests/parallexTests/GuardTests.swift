import XCTest
@testable import ParallexCore
import ParallexKit

/// Guard: a copy with its own Library can't open the original app's data,
/// even by its full path, and the attempt is recorded.
final class GuardTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)
    let realHome = FileManager.default.homeDirectoryForCurrentUser.path
    /// The fixture app's data folder in your real Library, which must never
    /// exist (nothing here reads or writes real data).
    var originalData: String { realHome + "/Library/Application Support/Guarded" }

    /// Only what these tests could have made is ever removed: never a
    /// folder that was there before (tearDown runs after a skip too).
    var originalDataWasThere = true

    override func setUpWithError() throws {
        originalDataWasThere = FileManager.default.fileExists(atPath: originalData)
        try XCTSkipIf(originalDataWasThere, "\(originalData) exists on this Mac")
        tempDir = try Fixtures.makeTempDirectory("guard")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
        setenv("PARALLEX_LAUNCHER", Fixtures.launcherBinary.path, 1)
        setenv("PARALLEX_HOME_LIBRARY", Fixtures.homeLibrary.path, 1)
        outDir = tempDir.appendingPathComponent("apps", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Only if Guard failed to stop the fixture's mkdir.
        if !originalDataWasThere {
            try? FileManager.default.removeItem(atPath: originalData)
        }
        unsetenv("PARALLEX_HOME")
        unsetenv("PARALLEX_LAUNCHER")
        unsetenv("PARALLEX_HOME_LIBRARY")
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// An app that tries each path in FIXTURE_TRY ("open:<path>" read-only,
    /// "mkdir:<path>") and writes one errno per line (0: it worked), then
    /// writes a file of its own in its Application Support.
    private func makeCopy() throws -> CreateResult {
        let app = try Fixtures.makeApp(named: "Guarded", bundleID: "com.fake.guarded", in: tempDir)
        let source = tempDir.appendingPathComponent("Guarded.m")
        try Data("""
        #import <Foundation/Foundation.h>
        #include <errno.h>
        #include <fcntl.h>
        #include <sys/stat.h>
        #include <sys/clonefile.h>
        #include <unistd.h>
        int main(void) {
            @autoreleasepool {
                NSMutableString *results = [NSMutableString string];
                NSString *tries = [NSString stringWithUTF8String:getenv("FIXTURE_TRY")];
                for (NSString *line in [tries componentsSeparatedByString:@"\\n"]) {
                    NSRange colon = [line rangeOfString:@":"];
                    NSString *op = [line substringToIndex:colon.location];
                    const char *path = [[line substringFromIndex:colon.location + 1] fileSystemRepresentation];
                    int result;
                    if ([op isEqualToString:@"mkdir"]) {
                        result = mkdir(path, 0755);
                    } else if ([op isEqualToString:@"clone"]) {
                        result = clonefile([[NSString stringWithUTF8String:getenv("FIXTURE_FILE")] fileSystemRepresentation], path, 0);
                    } else if ([op isEqualToString:@"link"]) {
                        result = symlink(path, [[NSString stringWithFormat:@"%s.link", getenv("FIXTURE_FILE")] fileSystemRepresentation]);
                    } else {
                        result = open(path, O_RDONLY);
                        if (result >= 0) close(result);
                    }
                    [results appendFormat:@"%d\\n", result < 0 ? errno : 0];
                }
                NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
                support = [support stringByAppendingPathComponent:@"Guarded"];
                [[NSFileManager defaultManager] createDirectoryAtPath:support withIntermediateDirectories:YES attributes:nil error:nil];
                BOOL own = [@"own" writeToFile:[support stringByAppendingPathComponent:@"own.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                [results appendFormat:@"own:%d\\n", own ? 1 : 0];
                [results writeToFile:[NSString stringWithUTF8String:getenv("FIXTURE_OUT")] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
            return 0;
        }
        """.utf8).write(to: source)
        let executable = app.appendingPathComponent("Contents/MacOS/Guarded")
        try? FileManager.default.removeItem(at: executable)
        try Shell.run("/usr/bin/clang", ["-fobjc-arc", "-framework", "Foundation", source.path, "-o", executable.path])
        var request = CreateRequest(appReference: app.path, name: "Guarded Work", outputDirectory: outDir)
        request.cloneApp = true
        return try InstanceCreator.create(request, builderOptions: options)
    }

    /// Run the copy trying `tries`; the errno of each, then whether its own
    /// file was written.
    private func run(_ copy: URL, _ tries: [String]) throws -> [String] {
        let out = tempDir.appendingPathComponent("out-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = copy.appendingPathComponent("Contents/MacOS/parallex-launcher")
        var environment = ProcessInfo.processInfo.environment
        environment["FIXTURE_OUT"] = out.path
        environment["FIXTURE_TRY"] = tries.joined(separator: "\n")
        let file = tempDir.appendingPathComponent("file-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        environment["FIXTURE_FILE"] = file.path
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: out.path) { usleep(50_000) }
        let text = try String(contentsOf: out, encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    func testTheListIsTheOriginalsData() throws {
        let app = try Fixtures.makeApp(named: "Listed", bundleID: "com.fake.listed", in: tempDir)
        let info = try AppInspector.inspect(app)
        let home = tempDir.appendingPathComponent("home").path
        let paths = Guard.locations(for: info, privateHomeItems: [".listed"], home: home)
        XCTAssertTrue(paths.contains("\(home)/Library/Application Support/Listed/"))
        XCTAssertTrue(paths.contains("\(home)/Library/Containers/com.fake.listed/"))
        XCTAssertTrue(paths.contains("\(home)/Library/Preferences/com.fake.listed.plist"))
        XCTAssertTrue(paths.contains("\(home)/Library/HTTPStorages/com.fake.listed/"))
        XCTAssertTrue(paths.contains("\(home)/.listed"))
        XCTAssertFalse(paths.contains { $0.contains("com.parallex.instance") }, "never the copy's own")
        XCTAssertEqual(paths.count, Set(paths).count)
    }

    func testACopyCantOpenTheOriginalsDataAndSaysSo() throws {
        let result = try makeCopy()
        XCTAssertEqual(result.manifest.guardedPaths?.contains(originalData + "/"), true)
        let cookies = originalData + "/Cookies"
        let results = try run(result.wrapperURL, [
            "open:\(cookies)",
            // Spelled otherwise, it's still the same folder.
            "open:\(realHome)//Library/./Application Support/Other/../Guarded/Cookies",
            "open:\(realHome)/library/application support/GUARDED/Cookies",
            "mkdir:\(originalData)",
            // By the data volume's own path, cloned into, linked to.
            "open:/System/Volumes/Data\(cookies)",
            "open:/\(cookies)",
            "open:/./system/volumes/data/\(cookies)",
            "clone:\(originalData)",
            "link:\(cookies)",
            // A folder that only starts with the same name isn't it.
            "open:\(originalData)Other/Cookies",
            // Your Library itself isn't the original's data.
            "open:\(realHome)/Library",
        ])
        XCTAssertEqual(results, [
            "\(EPERM)", "\(EPERM)", "\(EPERM)", "\(EPERM)", "\(EPERM)", "\(EPERM)", "\(EPERM)", "\(EPERM)", "\(EPERM)",
            "\(ENOENT)", "0", "own:1",
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalData))

        let report = try XCTUnwrap(IsolationCheck.recorded(result.manifest))
        XCTAssertTrue(report.isClean, "kept out isn't a leak: \(report.findings(in: .leak))")
        XCTAssertTrue(report.blocked.contains(cookies), "\(report.blocked)")
        XCTAssertTrue(report.blocked.contains(originalData))
        XCTAssertFalse(AccessRecord.entries(for: result.manifest).contains { !$0.wasBlocked && $0.path.hasPrefix(originalData) })
    }

    func testGuardCanBeTurnedOff() throws {
        let made = try makeCopy()
        var settings = made.manifest.effectiveSettings
        settings.guardOriginalData = false
        let result = try InstanceCreator.update(made.manifest, InstanceUpdate(settings: settings), builderOptions: options)
        XCTAssertNil(result.manifest.guardedPaths)
        XCTAssertEqual(try run(result.wrapperURL, ["open:\(originalData)/Cookies"]), ["\(ENOENT)", "own:1"])
        XCTAssertEqual(IsolationCheck.recorded(result.manifest)?.blocked, [])
    }
}
