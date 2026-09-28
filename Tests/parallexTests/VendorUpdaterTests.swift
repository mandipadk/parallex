import XCTest
@testable import ParallexCore
import ParallexKit

/// An app's own updater must never replace its copy: Sparkle installs the
/// vendor's build over a copy whenever the update's signature checks out,
/// which gives the copy the original's identity (and data) again.
final class VendorUpdaterTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("updaters")
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

    private func info(_ app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testCopiesGetNoSparkleFeed() throws {
        let target = try Fixtures.makeApp(named: "Sparkly", bundleID: "com.fake.sparkly", in: tempDir, extraInfoKeys: [
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": "K+UI4MY6BEJIHmHxyxmOvLZDrpUu3yt/ANqToWrtN1E=",
        ])
        var request = CreateRequest(appReference: target.path, name: "Sparkly Work", outputDirectory: outDir)
        request.cloneApp = true
        let copy = try InstanceCreator.create(request, builderOptions: options).wrapperURL
        let plist = try info(copy)
        XCTAssertNil(plist["SUFeedURL"], "no feed: Sparkle can't find an update to install over the copy")
        XCTAssertNotNil(plist["SUPublicEDKey"], "kept: without it Sparkle refuses to start and says so at every launch")
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, false)
        XCTAssertEqual(try info(target)["SUFeedURL"] as? String, "https://example.com/appcast.xml", "the original is untouched")
    }

    /// What Sparkle leaves behind when it installs the vendor's build over
    /// a copy: the original app, at the copy's path.
    func testACopyTheAppsUpdaterReplacedIsCaughtAndMadeACopyAgain() throws {
        let target = try Fixtures.makeApp(
            named: "Updaty", bundleID: "com.fake.updaty", in: tempDir,
            extraInfoKeys: ["CFBundleShortVersionString": "1.0"]
        )
        var request = CreateRequest(appReference: target.path, name: "Updaty Work", outputDirectory: outDir)
        request.cloneApp = true
        let result = try InstanceCreator.create(request, builderOptions: options)
        XCTAssertTrue(InstanceStatus.check(result.manifest).problems.isEmpty)

        let fm = FileManager.default
        try fm.removeItem(at: result.wrapperURL)
        try fm.copyItem(at: target, to: result.wrapperURL)

        let status = InstanceStatus.check(result.manifest)
        XCTAssertEqual(status.problems, [.copyReplaced])
        XCTAssertFalse(status.canLaunch, "it would open with the original's data")
        XCTAssertTrue(status.problems.allSatisfy(\.isMaintainable), "upkeep repairs it while it isn't running")
        XCTAssertThrowsError(try InstanceLauncher.launch(result.manifest)) { error in
            XCTAssertTrue("\(error)".contains("isn't a copy anymore"), "\(error)")
        }

        let repaired = try InstanceCreator.update(result.manifest, builderOptions: options)
        XCTAssertTrue(InstanceStatus.check(repaired.manifest).problems.isEmpty)
        XCTAssertEqual(try info(repaired.wrapperURL)["CFBundleIdentifier"] as? String, "com.parallex.instance.updaty-work")
        XCTAssertEqual(try info(repaired.wrapperURL)["CFBundleExecutable"] as? String, "parallex-launcher")
    }

    /// Only this instance's own replaced copy may be replaced: another
    /// app that happens to sit where a copy would go is left alone.
    func testSomeOtherAppInTheWayIsNeverReplaced() throws {
        let target = try Fixtures.makeApp(named: "Other", bundleID: "com.fake.other", in: tempDir)
        var request = CreateRequest(appReference: target.path, name: "Other Work", outputDirectory: outDir)
        request.cloneApp = true
        let result = try InstanceCreator.create(request, builderOptions: options)
        let fm = FileManager.default
        try fm.removeItem(at: result.wrapperURL)
        let stranger = try Fixtures.makeApp(named: "Stranger", bundleID: "com.fake.stranger", in: tempDir)
        try fm.copyItem(at: stranger, to: result.wrapperURL)

        XCTAssertThrowsError(try InstanceCreator.update(result.manifest, builderOptions: options))
        XCTAssertEqual(try info(result.wrapperURL)["CFBundleIdentifier"] as? String, "com.fake.stranger")
    }

    /// Stand-ins for Sparkle's and Squirrel's classes, compiled into a
    /// small app that reports what its updaters did.
    private func makeUpdaterApp(named name: String) throws -> URL {
        let app = try Fixtures.makeApp(named: name, bundleID: "com.fake.\(name.lowercased())", in: tempDir)
        let source = tempDir.appendingPathComponent("\(name).m")
        try Data("""
        #import <Foundation/Foundation.h>
        static NSMutableArray *report;
        @interface SPUUpdater : NSObject @end
        @implementation SPUUpdater
        - (void)checkForUpdates { [report addObject:@"sparkle-checked"]; }
        - (void)checkForUpdatesInBackground { [report addObject:@"sparkle-background"]; }
        - (BOOL)canCheckForUpdates { return YES; }
        - (NSURL *)feedURL { return [NSURL URLWithString:@"https://example.com/appcast.xml"]; }
        @end
        @interface SUUpdater : NSObject @end
        @implementation SUUpdater
        - (void)checkForUpdates:(id)sender { [report addObject:@"legacy-checked"]; }
        - (BOOL)automaticallyChecksForUpdates { return YES; }
        @end
        @interface SQRLUpdater : NSObject @property NSURLRequest *request; @end
        @implementation SQRLUpdater
        - (instancetype)initWithUpdateRequest:(NSURLRequest *)request { self = [super init]; _request = request; return self; }
        @end
        int main(void) {
            @autoreleasepool {
                report = [NSMutableArray array];
                SPUUpdater *updater = [SPUUpdater new];
                [updater checkForUpdates];
                [updater checkForUpdatesInBackground];
                [report addObject:updater.canCheckForUpdates ? @"can-check" : @"cannot-check"];
                [report addObject:updater.feedURL ? @"has-feed" : @"no-feed"];
                SUUpdater *legacy = [SUUpdater new];
                [legacy checkForUpdates:nil];
                [report addObject:legacy.automaticallyChecksForUpdates ? @"legacy-auto" : @"legacy-no-auto"];
                SQRLUpdater *squirrel = [[SQRLUpdater alloc] initWithUpdateRequest:
                    [NSURLRequest requestWithURL:[NSURL URLWithString:@"https://updates.example.com/check"]]];
                [report addObject:squirrel.request.URL.scheme];
                [[report componentsJoinedByString:@" "] writeToFile:[NSString stringWithUTF8String:getenv("FIXTURE_OUT")]
                    atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
            return 0;
        }
        """.utf8).write(to: source)
        let executable = app.appendingPathComponent("Contents/MacOS/\(name)")
        try? FileManager.default.removeItem(at: executable)
        try Shell.run("/usr/bin/clang", ["-fobjc-arc", "-framework", "Foundation", source.path, "-o", executable.path])
        try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        return app
    }

    private func run(_ app: URL, scope: URL?) throws -> String {
        let out = tempDir.appendingPathComponent("report-\(UUID().uuidString).txt")
        let process = Process()
        process.executableURL = app.appendingPathComponent("Contents/MacOS/\(app.deletingPathExtension().lastPathComponent)")
        var env = ProcessInfo.processInfo.environment
        env["FIXTURE_OUT"] = out.path
        env["DYLD_INSERT_LIBRARIES"] = Fixtures.homeLibrary.path
        env["PARALLEX_HOME_REDIRECT"] = tempDir.appendingPathComponent("home").path
        env["PARALLEX_HOME_SCOPE"] = scope?.path ?? tempDir.appendingPathComponent("elsewhere.app").path
        process.environment = env
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try String(contentsOf: out, encoding: .utf8)
    }

    func testTheCopysLibraryTurnsItsUpdatersOff() throws {
        let app = try makeUpdaterApp(named: "Updaters")
        XCTAssertEqual(
            try run(app, scope: app),
            "cannot-check no-feed legacy-no-auto parallex-no-update"
        )
    }

    func testUpdatersOutsideTheCopyAreLeftAlone() throws {
        let app = try makeUpdaterApp(named: "Outsider")
        XCTAssertEqual(
            try run(app, scope: nil),
            "sparkle-checked sparkle-background can-check has-feed legacy-checked legacy-auto https"
        )
    }
}
