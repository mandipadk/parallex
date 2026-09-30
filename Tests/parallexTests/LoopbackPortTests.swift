import XCTest
@testable import ParallexCore
import ParallexKit

/// An app that finds a running copy of itself on a fixed port on this Mac
/// (Zed does) would, as a copy, find the original and hand over to it. In a
/// copy, that port is one of its own.
final class LoopbackPortTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("ports")
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
        unsetenv("PARALLEX_LOOPBACK_PORTS_FOR")
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A socket listening on a free port of 127.0.0.1 in this process.
    private func listen() throws -> (socket: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(fd, 4), 0)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, Int(UInt16(bigEndian: address.sin_port)))
    }

    func testTheAppsPortIsTheCopysOwn() throws {
        let known = try listen()      // the "original" answering on the app's port
        let other = try listen()      // something else on this Mac
        defer { close(known.socket); close(other.socket) }
        setenv("PARALLEX_LOOPBACK_PORTS_FOR", "com.fake.porty=\(known.port)", 1)

        let app = try Fixtures.makeApp(named: "Porty", bundleID: "com.fake.porty", in: tempDir)
        let source = tempDir.appendingPathComponent("Porty.c")
        try Data("""
        #include <arpa/inet.h>
        #include <errno.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <sys/socket.h>
        #include <unistd.h>
        static struct sockaddr_in at(int port) {
            struct sockaddr_in a = {0};
            a.sin_family = AF_INET; a.sin_port = htons(port); a.sin_addr.s_addr = inet_addr("127.0.0.1");
            return a;
        }
        static int reach(int port) {
            int fd = socket(AF_INET, SOCK_STREAM, 0);
            struct sockaddr_in a = at(port);
            int r = connect(fd, (struct sockaddr *)&a, sizeof a) == 0 ? 0 : errno;
            close(fd);
            return r;
        }
        int main(void) {
            int known = atoi(getenv("FIXTURE_KNOWN")), other = atoi(getenv("FIXTURE_OTHER"));
            FILE *out = fopen(getenv("FIXTURE_OUT"), "w");
            fprintf(out, "%d ", reach(known));            // the original isn't found
            int fd = socket(AF_INET, SOCK_STREAM, 0);
            struct sockaddr_in a = at(known);
            fprintf(out, "%d ", bind(fd, (struct sockaddr *)&a, sizeof a) == 0 ? 0 : errno);
            listen(fd, 4);
            fprintf(out, "%d ", reach(known));            // it finds itself
            fprintf(out, "%d", reach(other));             // other ports are as they are
            fclose(out);
            return 0;
        }
        """.utf8).write(to: source)
        let executable = app.appendingPathComponent("Contents/MacOS/Porty")
        try? FileManager.default.removeItem(at: executable)
        try Shell.run("/usr/bin/clang", [source.path, "-o", executable.path])
        var request = CreateRequest(appReference: app.path, name: "Porty Work", mode: .launchOnly, outputDirectory: outDir)
        request.cloneApp = true
        let result = try InstanceCreator.create(request, builderOptions: options)

        let out = tempDir.appendingPathComponent("out")
        let process = Process()
        process.executableURL = result.wrapperURL.appendingPathComponent("Contents/MacOS/parallex-launcher")
        var environment = ProcessInfo.processInfo.environment
        environment["FIXTURE_OUT"] = out.path
        environment["FIXTURE_KNOWN"] = "\(known.port)"
        environment["FIXTURE_OTHER"] = "\(other.port)"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "\(ECONNREFUSED) 0 0 0")
    }

    func testEachCopyHasItsOwnAndKeepsIt() throws {
        setenv("PARALLEX_LOOPBACK_PORTS_FOR", "com.fake.twin=40123", 1)
        let app = try Fixtures.makeApp(named: "Twin", bundleID: "com.fake.twin", in: tempDir)
        var manifests: [InstanceManifest] = []
        for name in ["Twin One", "Twin Two"] {
            var request = CreateRequest(appReference: app.path, name: name, mode: .launchOnly, outputDirectory: outDir)
            request.cloneApp = true
            manifests.append(try InstanceCreator.create(request, builderOptions: options).manifest)
        }
        let one = try XCTUnwrap(manifests[0].loopbackPorts?["40123"])
        let two = try XCTUnwrap(manifests[1].loopbackPorts?["40123"])
        XCTAssertNotEqual(one, two)
        XCTAssertTrue(LoopbackPorts.range.contains(one))
        let rebuilt = try InstanceCreator.update(manifests[0], builderOptions: options)
        XCTAssertEqual(rebuilt.manifest.loopbackPorts?["40123"], one, "kept through a rebuild")
    }

    func testZedsPortIsKnown() {
        XCTAssertEqual(Presets.singleInstancePorts(for: "dev.zed.Zed"), [43937 + Int(getuid())])
        XCTAssertEqual(Presets.singleInstancePorts(for: "com.fake.nothing"), [])
    }
}
