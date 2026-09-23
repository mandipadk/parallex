import XCTest
@testable import ParallexCore
import ParallexKit

/// Instance liveness comes from the launcher's pidfile (execv keeps the PID),
/// validated against the process's executable path — bundle-ID lookups fail
/// because exec'd instances re-register under the target's identity, and
/// modern macOS hides other processes' environments.
final class RunningTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("running")
        setenv("PARALLEX_HOME", tempDir.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writePidFile(slug: String, pid: pid_t) throws {
        let url = Paths.pidFile(slug: slug)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("\(pid)".utf8).write(to: url)
    }

    /// A live process with a known executable: this very test runner.
    private var ownBinary: String {
        var buffer = [CChar](repeating: 0, count: 4096)
        _ = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
        return String(cString: buffer)
    }

    func testLivePidWithMatchingBinaryIsRunning() throws {
        try writePidFile(slug: "alive", pid: getpid())
        XCTAssertEqual(Running.processID(instanceSlug: "alive", targetBinary: ownBinary), getpid())
        XCTAssertTrue(Running.isRunning(instanceSlug: "alive", targetBinary: ownBinary))
    }

    func testBinaryMismatchIsNotRunning() throws {
        // PID is alive but runs a different binary — e.g. the PID was reused
        // after a reboot, or the pidfile is stale.
        try writePidFile(slug: "mismatch", pid: getpid())
        XCTAssertFalse(Running.isRunning(instanceSlug: "mismatch", targetBinary: "/bin/ls"))
    }

    func testDeadPidIsNotRunning() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        try writePidFile(slug: "dead", pid: process.processIdentifier)
        XCTAssertFalse(Running.isRunning(instanceSlug: "dead", targetBinary: "/usr/bin/true"))
    }

    func testRecordedExecutableWinsOverManifestBinary() throws {
        // 0.5+ launchers record the executable they exec'd; if the target app
        // moved since the manifest was written, that's the one to match.
        let url = Paths.pidFile(slug: "moved")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(PidFileRecord(pid: getpid(), executablePath: ownBinary).serialized.utf8).write(to: url)
        XCTAssertTrue(Running.isRunning(instanceSlug: "moved", targetBinary: "/Applications/Old.app/Contents/MacOS/Old"))
    }

    func testPidFileRecordParsing() {
        XCTAssertEqual(PidFileRecord(parsing: "42"), PidFileRecord(pid: 42, executablePath: nil))
        XCTAssertEqual(
            PidFileRecord(parsing: "42\n/Applications/My App.app/Contents/MacOS/My App\n"),
            PidFileRecord(pid: 42, executablePath: "/Applications/My App.app/Contents/MacOS/My App")
        )
        XCTAssertNil(PidFileRecord(parsing: "-3"))
        XCTAssertNil(PidFileRecord(parsing: ""))
    }

    func testMissingOrGarbagePidFile() throws {
        XCTAssertFalse(Running.isRunning(instanceSlug: "no-pidfile", targetBinary: "/bin/ls"))
        try writePidFile(slug: "garbage", pid: 0)
        XCTAssertFalse(Running.isRunning(instanceSlug: "garbage", targetBinary: "/bin/ls"))
        let url = Paths.pidFile(slug: "junk")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-a-pid".utf8).write(to: url)
        XCTAssertFalse(Running.isRunning(instanceSlug: "junk", targetBinary: "/bin/ls"))
    }
}
