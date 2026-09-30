import XCTest
@testable import ParallexCore
import ParallexKit

/// A workspace's proxy, for its instances and `parallex run`.
final class WorkspaceNetworkTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("network")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
        setenv("PARALLEX_LAUNCHER", Fixtures.launcherBinary.path, 1)
        outDir = tempDir.appendingPathComponent("apps", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        unsetenv("PARALLEX_LAUNCHER")
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testProxyAddresses() {
        XCTAssertEqual(WorkspaceNetwork.normalize("proxy.example:8080"), "http://proxy.example:8080")
        XCTAssertEqual(WorkspaceNetwork.normalize(" SOCKS5://127.0.0.1:1080 "), "socks5://127.0.0.1:1080")
        XCTAssertNil(WorkspaceNetwork.normalize("http://me:secret@proxy.example:3128"), "a password would be in every process's arguments")
        XCTAssertEqual(WorkspaceNetwork.chromiumSwitch(proxy: "socks5h://127.0.0.1:1080"), "socks5://127.0.0.1:1080")
        XCTAssertEqual(WorkspaceNetwork.environment(proxy: "http://p:1")["NO_PROXY"], "localhost,127.0.0.1,::1")
        XCTAssertNil(WorkspaceNetwork.environment(proxy: "http://p:1", base: ["no_proxy": "corp"])["NO_PROXY"], "yours stays")
        XCTAssertNil(WorkspaceNetwork.normalize("proxy.example"), "a port is needed")
        XCTAssertNil(WorkspaceNetwork.normalize("ftp://proxy.example:21"))
        XCTAssertNil(WorkspaceNetwork.normalize("http://proxy.example:8080/path"))
        XCTAssertNil(WorkspaceNetwork.normalize("http://proxy.example:8080 --flag"))
    }

    func testAnElectronAppInTheWorkspaceGoesThroughItsProxy() throws {
        let app = try Fixtures.makeApp(named: "Chatter", bundleID: "com.fake.chatter", in: tempDir, electron: true)
        let source = tempDir.appendingPathComponent("Chatter.c")
        try Data("""
        #include <stdio.h>
        #include <stdlib.h>
        int main(int argc, char **argv) {
            FILE *out = fopen(getenv("FIXTURE_OUT"), "w");
            for (int i = 1; i < argc; i++) fprintf(out, "%s\\n", argv[i]);
            const char *proxy = getenv("HTTPS_PROXY");
            fprintf(out, "HTTPS_PROXY=%s\\n", proxy ? proxy : "");
            fclose(out);
            return 0;
        }
        """.utf8).write(to: source)
        let executable = app.appendingPathComponent("Contents/MacOS/Chatter")
        try? FileManager.default.removeItem(at: executable)
        try Shell.run("/usr/bin/clang", [source.path, "-o", executable.path])
        let made = try InstanceCreator.create(
            CreateRequest(appReference: app.path, name: "Chatter Work", outputDirectory: outDir), builderOptions: options
        )

        func launch() throws -> [String] {
            let out = tempDir.appendingPathComponent("out-\(UUID().uuidString)")
            let process = Process()
            process.executableURL = made.wrapperURL.appendingPathComponent("Contents/MacOS/launcher")
            var environment = ProcessInfo.processInfo.environment
            environment["FIXTURE_OUT"] = out.path
            environment.removeValue(forKey: "HTTPS_PROXY")
            process.environment = environment
            try process.run()
            process.waitUntilExit()
            return try String(contentsOf: out, encoding: .utf8).split(separator: "\n").map(String.init)
        }

        XCTAssertFalse(try launch().contains { $0.hasPrefix("--proxy-server") })
        let workspace = try WorkspaceStore.create(name: "Client A", members: [made.manifest.slug])
        try WorkspaceStore.update(id: workspace.id) { $0.proxy = "http://proxy.client.example:8080" }
        let proxied = try launch()
        XCTAssertTrue(proxied.contains("--proxy-server=http://proxy.client.example:8080"), "\(proxied)")
        XCTAssertTrue(proxied.contains("HTTPS_PROXY=http://proxy.client.example:8080"))
        try WorkspaceStore.update(id: workspace.id) { $0.proxy = nil }
        XCTAssertFalse(try launch().contains { $0.hasPrefix("--proxy-server") }, "off again")
    }
}
