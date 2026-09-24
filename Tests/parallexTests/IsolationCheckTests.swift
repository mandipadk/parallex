import XCTest
@testable import ParallexCore
import ParallexKit

/// The classifier behind `parallex check`: which open files count as the
/// original's data, which are shared by macOS identity, which by choice.
final class IsolationCheckTests: XCTestCase {
    var tempDir: URL!
    let home = "/private/tmp/parallex-fake-home"

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("isolation")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func manifest(
        bundleID: String, appName: String, environment: [String: String] = [:], preset: String? = nil
    ) throws -> InstanceManifest {
        let app = try Fixtures.makeApp(named: appName, bundleID: bundleID, in: tempDir, electron: true)
        return InstanceManifest(
            name: "\(appName) Work", slug: "work", bundleIdentifier: "com.parallex.instance.work",
            targetApp: app.path, targetBinary: app.appendingPathComponent("Contents/MacOS/\(appName)").path,
            wrapperPath: "/Applications/\(appName) Work.app", mode: .dataDir, preset: preset,
            arguments: [], environment: environment, homeSymlinks: nil, createdAt: Date(),
            parallexVersion: ParallexConfig.version, targetBundleID: bundleID
        )
    }

    func testClassifiesClaudeInstanceFiles() throws {
        let manifest = try manifest(
            bundleID: "com.anthropic.claudefordesktop", appName: "Claude",
            preset: "com.anthropic.claudefordesktop"
        )
        let rules = IsolationCheck.Rules(manifest: manifest, home: home)
        // Files outside the home folder (bundles, system) aren't classified.
        XCTAssertNil(rules.classify("/Applications/Claude.app/Contents/Resources/app.asar"))
        // Claude opens its logs by app name before any setting applies.
        XCTAssertEqual(rules.classify("\(home)/Library/Logs/Claude/main.log")?.category, .sharedByIdentity)
        XCTAssertEqual(rules.classify("\(home)/Library/Application Support/Claude/config.json")?.category, .leak)
        XCTAssertEqual(
            rules.classify("\(home)/Library/Caches/com.anthropic.claudefordesktop/Cache.db")?.category,
            .sharedByIdentity
        )
        // Claude Code config is shared on purpose while the option is off…
        XCTAssertEqual(rules.classify("\(home)/.claude/settings.json")?.category, .sharedByChoice)
        XCTAssertEqual(rules.classify("\(home)/Documents/notes.md")?.category, .other)
    }

    func testSeparatedClaudeCodeConfigCountsAsLeakWhenTouched() throws {
        let manifest = try manifest(
            bundleID: "com.anthropic.claudefordesktop", appName: "Claude",
            environment: ["CLAUDE_CONFIG_DIR": "/somewhere"], preset: "com.anthropic.claudefordesktop"
        )
        let rules = IsolationCheck.Rules(manifest: manifest, home: home)
        XCTAssertEqual(rules.classify("\(home)/.claude/settings.json")?.category, .leak)
    }

    func testInstanceDirectoryIsIsolated() throws {
        let manifest = try manifest(bundleID: "com.fake.app", appName: "Fake")
        // PARALLEX_HOME lives in the temp dir; treat its parent as "home".
        let instanceDir = Paths.instanceDir(slug: "work").path
        let rules = IsolationCheck.Rules(manifest: manifest, home: (instanceDir as NSString).deletingLastPathComponent)
        XCTAssertEqual(rules.classify(instanceDir + "/data/Local Storage/leveldb/LOG")?.category, .isolated)
    }

    func testOwnProcessTreeAndFilesAreReadable() throws {
        // Smoke test of the libproc plumbing against this test process.
        let file = tempDir.appendingPathComponent("held-open.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let open = IsolationCheck.openFiles(of: getpid())
        XCTAssertTrue(open.contains { $0.hasSuffix("held-open.txt") }, "\(open)")
        XCTAssertTrue(IsolationCheck.processTree(root: getpid(), alsoMatching: "\u{1}never").contains(getpid()))
        XCTAssertFalse(IsolationCheck.arguments(of: getpid()).isEmpty)
    }

    func testOnlyRoutineProblemsAreMaintainedAutomatically() {
        XCTAssertTrue(InstanceStatus.Problem.wrapperOutdated(builtWith: "0.6.0").isMaintainable)
        XCTAssertTrue(InstanceStatus.Problem.targetMoved(to: "/Applications/X.app").isMaintainable)
        XCTAssertTrue(InstanceStatus.Problem.cloneOutdated(copyOf: "1", original: "2").isMaintainable)
        // These need the user: a missing wrapper can be a deliberate removal,
        // a missing app needs locating.
        XCTAssertFalse(InstanceStatus.Problem.wrapperMissing.isMaintainable)
        XCTAssertFalse(InstanceStatus.Problem.targetMissing.isMaintainable)
    }

    func testVersionComparison() {
        XCTAssertEqual(InstanceStatus.compareVersions("0.4.0", "0.5.0"), .orderedAscending)
        XCTAssertEqual(InstanceStatus.compareVersions("0.10.0", "0.9.9"), .orderedDescending)
        XCTAssertEqual(InstanceStatus.compareVersions("1.0", "1.0.0"), .orderedSame)
    }

    /// A copy whose redirect library macOS didn't load is flagged, even though
    /// no file it has open looks wrong.
    func testNoticesWhenTheSeparationLibraryIsntLoaded() throws {
        let source = tempDir.appendingPathComponent("sleeper.c")
        let probe = tempDir.appendingPathComponent("sleeper")
        try "#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        _ = try Shell.run("/usr/bin/clang", [source.path, "-o", probe.path])

        func start(inserting library: URL?) throws -> Process {
            let process = Process()
            process.executableURL = probe
            var environment = ProcessInfo.processInfo.environment
            environment["DYLD_INSERT_LIBRARIES"] = library?.path
            process.environment = environment
            try process.run()
            Thread.sleep(forTimeInterval: 0.3)
            return process
        }
        var manifest = try manifest(bundleID: "com.fake.native", appName: "Native")
        manifest.redirectedHome = tempDir.appendingPathComponent("home").path

        let plain = try start(inserting: nil)
        defer { plain.terminate() }
        let missing = IsolationCheck.inactiveLibraries(manifest, pid: plain.processIdentifier)
        XCTAssertEqual(missing.map(\.category), [.leak])
        XCTAssertEqual(missing.first?.path, "libparallexhome.dylib")

        // Under the name it ships with.
        let library = tempDir.appendingPathComponent("libparallexhome.dylib")
        try FileManager.default.copyItem(at: Fixtures.homeLibrary, to: library)
        let redirected = try start(inserting: library)
        defer { redirected.terminate() }
        XCTAssertTrue(IsolationCheck.mappedFiles(of: redirected.processIdentifier).contains {
            $0.hasSuffix("/libparallexhome.dylib")
        })
        XCTAssertEqual(IsolationCheck.inactiveLibraries(manifest, pid: redirected.processIdentifier), [])

        manifest.redirectedHome = nil
        XCTAssertEqual(IsolationCheck.inactiveLibraries(manifest, pid: plain.processIdentifier), [],
                       "copies that don't use the library aren't checked for it")
    }
}
