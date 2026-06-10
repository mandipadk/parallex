import XCTest
@testable import ParallexCore
import ParallexKit

/// End-to-end tests of the real `parallex-launcher` binary: build a wrapper
/// bundle around it by hand, run the wrapper's executable, and observe what
/// the exec'd target sees. This exercises the exact mechanism production
/// wrappers use (Bundle.main config → environment setup → execv).
final class LauncherIntegrationTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("launcher")
        guard FileManager.default.isExecutableFile(atPath: Fixtures.launcherBinary.path) else {
            throw XCTSkip("parallex-launcher not built")
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Assemble a wrapper around the real launcher with the given config.
    private func makeWrapper(config: [String: Any]) throws -> URL {
        let fm = FileManager.default
        let app = tempDir.appendingPathComponent("Test Wrapper.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleIdentifier": "com.parallex.test.wrapper",
            "CFBundleName": "Test Wrapper",
            "CFBundleExecutable": "launcher",
            "CFBundlePackageType": "APPL",
            ParallexConfig.rootKey: config,
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))
        try fm.copyItem(at: Fixtures.launcherBinary, to: macOS.appendingPathComponent("launcher"))
        return app
    }

    /// Run the wrapper's launcher binary and capture its output.
    private func runWrapper(
        _ app: URL,
        environment: [String: String] = [:]
    ) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = app.appendingPathComponent("Contents/MacOS/launcher")
        var env = ProcessInfo.processInfo.environment
        env["PARALLEX_LAUNCHER_NO_UI"] = "1" // never block tests on a dialog
        env.merge(environment) { _, new in new }
        process.environment = env
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self),
            process.terminationStatus
        )
    }

    func testExecsTargetWithArguments() throws {
        let app = try makeWrapper(config: [
            ParallexConfig.Key.targetBinary: "/bin/echo",
            ParallexConfig.Key.arguments: ["hello-from-parallex"],
        ])
        let result = try runWrapper(app)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, "hello-from-parallex\n")
    }

    func testSetsEnvironmentVariables() throws {
        let app = try makeWrapper(config: [
            ParallexConfig.Key.targetBinary: "/bin/sh",
            ParallexConfig.Key.arguments: ["-c", "printf '%s' \"$PARALLEX_SMOKE\""],
            ParallexConfig.Key.environment: ["PARALLEX_SMOKE": "it-works"],
        ])
        let result = try runWrapper(app)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, "it-works")
    }

    func testWritesPidFileBeforeExec() throws {
        let pidFile = tempDir.appendingPathComponent("run/instance.pid")
        let app = try makeWrapper(config: [
            ParallexConfig.Key.targetBinary: "/usr/bin/true",
            ParallexConfig.Key.pidFile: pidFile.path,
        ])
        let process = Process()
        process.executableURL = app.appendingPathComponent("Contents/MacOS/launcher")
        var env = ProcessInfo.processInfo.environment
        env["PARALLEX_LAUNCHER_NO_UI"] = "1"
        process.environment = env
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        // execv kept the PID, so the file must contain the launcher's own PID.
        let recorded = try String(contentsOf: pidFile, encoding: .utf8)
        XCTAssertEqual(recorded, "\(process.processIdentifier)")
    }

    func testCreatesConfiguredDirectories() throws {
        let dataDir = tempDir.appendingPathComponent("made-by-launcher/data")
        let app = try makeWrapper(config: [
            ParallexConfig.Key.targetBinary: "/usr/bin/true",
            ParallexConfig.Key.createDirectories: [dataDir.path],
        ])
        let result = try runWrapper(app)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataDir.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testHomeOverrideScaffoldsAndExports() throws {
        let fm = FileManager.default
        // A fake "real home" containing a Downloads folder to share.
        let realHome = tempDir.appendingPathComponent("real-home")
        try fm.createDirectory(
            at: realHome.appendingPathComponent("Downloads"),
            withIntermediateDirectories: true
        )
        let instanceHome = tempDir.appendingPathComponent("instance-home")

        let app = try makeWrapper(config: [
            ParallexConfig.Key.targetBinary: "/bin/sh",
            ParallexConfig.Key.arguments: ["-c", "printf '%s' \"$HOME\""],
            ParallexConfig.Key.homeOverride: instanceHome.path,
            ParallexConfig.Key.homeSymlinks: ["Downloads", ".missing-item"],
        ])
        let result = try runWrapper(app, environment: ["HOME": realHome.path])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        // The target saw the instance home...
        XCTAssertEqual(result.stdout, instanceHome.path)
        // ...the Library skeleton exists...
        for subdir in ["Library/Preferences", "Library/Application Support", "Library/Caches"] {
            XCTAssertTrue(
                fm.fileExists(atPath: instanceHome.appendingPathComponent(subdir).path),
                "missing \(subdir)"
            )
        }
        // ...Downloads is a symlink back to the real home...
        let link = instanceHome.appendingPathComponent("Downloads")
        XCTAssertEqual(
            try fm.destinationOfSymbolicLink(atPath: link.path),
            realHome.appendingPathComponent("Downloads").path
        )
        // ...and items absent from the real home were skipped.
        XCTAssertNil(try? fm.attributesOfItem(atPath: instanceHome.appendingPathComponent(".missing-item").path))
    }

    func testMissingTargetFailsWithClearMessage() throws {
        let app = try makeWrapper(config: [
            ParallexConfig.Key.targetBinary: "/nonexistent/binary",
        ])
        let result = try runWrapper(app)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("no longer exists"), result.stderr)
        XCTAssertTrue(result.stderr.contains("/nonexistent/binary"), result.stderr)
    }

    func testMissingConfigFailsWithClearMessage() throws {
        let fm = FileManager.default
        // Wrapper with no Parallex dict at all.
        let app = tempDir.appendingPathComponent("Broken Wrapper.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.parallex.test.broken",
            "CFBundleExecutable": "launcher",
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plistData.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try fm.copyItem(at: Fixtures.launcherBinary, to: macOS.appendingPathComponent("launcher"))

        let result = try runWrapper(app)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("parallex create"), result.stderr)
    }
}
