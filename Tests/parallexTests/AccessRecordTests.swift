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

/// Learning from the record: hidden folders of yours a copy writes to
/// through its home's links are offered to keep to it.
final class PrivateSuggestionTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)
    let realHome = FileManager.default.homeDirectoryForCurrentUser.path

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("suggest")
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

    func testWhichItemAPathBelongsTo() {
        let home = "/h"
        XCTAssertEqual(PrivateSuggestions.item(for: "/h/.config/acme/settings.json", home: home), ".config/acme")
        XCTAssertEqual(PrivateSuggestions.item(for: "/h/.local/share/acme/db", home: home), ".local/share/acme")
        XCTAssertEqual(PrivateSuggestions.item(for: "/h/.acme/token", home: home), ".acme")
        XCTAssertNil(PrivateSuggestions.item(for: "/h/.config", home: home))
        XCTAssertNil(PrivateSuggestions.item(for: "/h/.local/share", home: home))
        XCTAssertNil(PrivateSuggestions.item(for: "/h/.ssh/known_hosts", home: home), "yours on purpose")
        XCTAssertNil(PrivateSuggestions.item(for: "/h/.cache/acme/x", home: home))
        XCTAssertNil(PrivateSuggestions.item(for: "/h/Documents/notes.txt", home: home), "your files")
        XCTAssertNil(PrivateSuggestions.item(for: "/elsewhere/.acme", home: home))
    }

    func testWritesThroughTheHomeBecomeSuggestionsAndCanBeKept() throws {
        let app = try Fixtures.makeApp(named: "Chatty", bundleID: "com.fake.chatty", in: tempDir)
        var request = CreateRequest(appReference: app.path, name: "Chatty Work", mode: .launchOnly, outputDirectory: outDir)
        request.cloneApp = true
        let made = try InstanceCreator.create(request, builderOptions: options)
        let log = Paths.instanceDir(slug: made.manifest.slug).appendingPathComponent("access.log")
        let now = Int(Date().timeIntervalSince1970)
        let lines = [
            "\(now)\t1\tChatty\twrite\t\(realHome)/.config/acme-cloud/state.json",
            "\(now)\t1\tChatty\tcreate\t\(realHome)/.config/acme-cloud/cache",
            "\(now)\t1\tChatty\tread\t\(realHome)/.config/other/x",
            "\(now)\t1\tChatty\twrite\t\(realHome)/.chatty/own",
            "\(now)\t1\tChatty\twrite\t\(realHome)/.ssh/known_hosts",
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: log)

        let suggestions = PrivateSuggestions.suggestions(for: made.manifest)
        XCTAssertEqual(suggestions.map(\.item), [".config/acme-cloud"], "reads, the app's own and yours on purpose aren't")
        XCTAssertEqual(suggestions.first?.writes, 2)

        var settings = made.manifest.effectiveSettings
        settings.extraPrivateItems = [".config/acme-cloud", "../escape", "Library/Preferences"]
        let kept = try InstanceCreator.update(made.manifest, InstanceUpdate(settings: settings), builderOptions: options)
        XCTAssertEqual(kept.manifest.privateHomeItems?.contains(".config/acme-cloud"), true)
        XCTAssertEqual(kept.manifest.privateHomeItems?.contains("../escape"), false)
        XCTAssertEqual(kept.manifest.privateHomeItems?.contains("Library/Preferences"), false)
        XCTAssertEqual(kept.manifest.guardedPaths?.contains("\(realHome)/.config/acme-cloud"), true, "and Guard keeps the copy out of yours")
        XCTAssertTrue(PrivateSuggestions.suggestions(for: kept.manifest).isEmpty)

        // Shared again: the copy's own version goes, and its home links to
        // yours there again.
        let home = try XCTUnwrap(kept.manifest.redirectedHome)
        let config = URL(fileURLWithPath: home).appendingPathComponent(".config")
        let own = config.appendingPathComponent("acme-cloud")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try Data("copy's".utf8).write(to: own.appendingPathComponent("state.json"))
        try FileManager.default.createSymbolicLink(at: config.appendingPathComponent("other"), withDestinationURL: tempDir)
        setenv("PARALLEX_TRASH", tempDir.appendingPathComponent("trash").path, 1)
        defer { unsetenv("PARALLEX_TRASH") }
        settings.extraPrivateItems = nil
        let shared = try InstanceCreator.update(kept.manifest, InstanceUpdate(settings: settings), builderOptions: options)
        XCTAssertEqual(shared.manifest.privateHomeItems?.contains(".config/acme-cloud"), false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.path), "to the Trash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path), "a folder of only links goes, to be linked again")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path), "links are removed, never what they lead to")
    }

    /// Before the copy has made its own ~/.config, its home's .config is a
    /// link to yours: sharing an item again must never touch yours.
    func testSharingAgainNeverReachesYourFolderThroughALink() throws {
        let yours = tempDir.appendingPathComponent("your-config", isDirectory: true)
        try FileManager.default.createDirectory(at: yours.appendingPathComponent("acme-cloud"), withIntermediateDirectories: true)
        try Data("yours".utf8).write(to: yours.appendingPathComponent("acme-cloud/state.json"))
        let home = tempDir.appendingPathComponent("copy-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".config"), withDestinationURL: yours)
        setenv("PARALLEX_TRASH", tempDir.appendingPathComponent("trash").path, 1)
        defer { unsetenv("PARALLEX_TRASH") }
        InstanceCreator.releasePrivateItems([".config/acme-cloud"], home: home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: yours.appendingPathComponent("acme-cloud/state.json").path))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".config").path))
    }
}
