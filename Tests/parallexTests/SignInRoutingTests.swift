import XCTest
@testable import ParallexCore
import ParallexKit

/// A sign-in link coming back (`app://…?state=…`) goes to the copy that
/// started that sign-in, not the one used most recently.
final class SignInRoutingTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("signin")
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

    func testReadingTheStateOfARequestAndOfTheLinkBack() throws {
        let request = try XCTUnwrap(URL(string: "https://auth.example.com/authorize?response_type=code&client_id=app&state=s1&redirect_uri=app://cb"))
        XCTAssertTrue(SignInRequests.isRequest(request))
        XCTAssertEqual(SignInRequests.state(in: request), "s1")
        XCTAssertEqual(SignInRequests.state(in: try XCTUnwrap(URL(string: "app://cb?code=c&state=s1"))), "s1")
        XCTAssertEqual(SignInRequests.state(in: try XCTUnwrap(URL(string: "app://cb#access_token=t&state=s2"))), "s2")
        XCTAssertFalse(SignInRequests.isRequest(try XCTUnwrap(URL(string: "https://example.com/?state=on"))), "a state alone isn't a sign-in")
        XCTAssertFalse(SignInRequests.isRequest(try XCTUnwrap(URL(string: "https://example.com/authorize?client_id=app"))))
    }

    /// A copy (its own Library) opening a sign-in page through NSWorkspace,
    /// as apps and Electron's shell.openExternal do.
    private func makeCopy(named name: String) throws -> CreateResult {
        let app = try Fixtures.makeApp(named: name, bundleID: "com.fake.\(name.lowercased())", in: tempDir)
        let source = tempDir.appendingPathComponent("\(name).m")
        try Data("""
        #import <AppKit/AppKit.h>
        int main(void) {
            @autoreleasepool {
                NSString *address = [NSString stringWithUTF8String:getenv("FIXTURE_URL")];
                [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:address]];
            }
            return 0;
        }
        """.utf8).write(to: source)
        let executable = app.appendingPathComponent("Contents/MacOS/\(name)")
        try? FileManager.default.removeItem(at: executable)
        try Shell.run("/usr/bin/clang", ["-fobjc-arc", "-framework", "AppKit", source.path, "-o", executable.path])
        var request = CreateRequest(appReference: app.path, name: "\(name) Work", outputDirectory: outDir)
        request.cloneApp = true
        return try InstanceCreator.create(request, builderOptions: options)
    }

    private func open(_ copy: URL, _ address: String) throws {
        let process = Process()
        process.executableURL = copy.appendingPathComponent("Contents/MacOS/parallex-launcher")
        var environment = ProcessInfo.processInfo.environment
        environment["FIXTURE_URL"] = address
        environment["PARALLEX_OPEN_URL_DRY_RUN"] = "1" // never a real browser
        process.environment = environment
        try process.run()
        process.waitUntilExit()
    }

    func testACopyNotesTheSignInItStartsAndTheLinkBackFindsIt() throws {
        let work = try makeCopy(named: "Asker")
        let home = try makeCopy(named: "Other")
        try open(work.wrapperURL, "https://auth.example.com/authorize?client_id=app&state=from-work&redirect_uri=asker://cb")
        try open(home.wrapperURL, "https://example.com/news?state=not-a-sign-in")
        let manifests = [work.manifest, home.manifest]
        XCTAssertEqual(SignInRequests.requester(of: "from-work", manifests: manifests), work.manifest.slug)
        XCTAssertNil(SignInRequests.requester(of: "not-a-sign-in", manifests: manifests))

        let candidates = [
            LinkRouting.Candidate(pid: 100, name: "Asker (original)", isInstance: false),
            LinkRouting.Candidate(pid: 200, name: "Asker Work", isInstance: true, slug: work.manifest.slug),
            LinkRouting.Candidate(pid: 300, name: "Other Work", isInstance: true, slug: home.manifest.slug),
        ]
        let back = try XCTUnwrap(URL(string: "asker://cb?code=c&state=from-work"))
        XCTAssertEqual(SignInRequests.narrow(candidates, for: back, manifests: manifests).map(\.pid), [200])

        // Nobody here asked (the original did, which notes nothing): the
        // copies that would have noted it are out.
        let other = try XCTUnwrap(URL(string: "asker://cb?code=c&state=elsewhere"))
        XCTAssertEqual(SignInRequests.narrow(candidates, for: other, manifests: manifests).map(\.pid), [100])
        // No state: nothing to go on.
        let plain = try XCTUnwrap(URL(string: "asker://open/thing"))
        XCTAssertEqual(SignInRequests.narrow(candidates, for: plain, manifests: manifests).count, 3)
    }

    func testOldRequestsAreForgotten() throws {
        let copy = try makeCopy(named: "Stale")
        SignInRequests.record(state: "old", slug: copy.manifest.slug, at: Date().addingTimeInterval(-3600))
        XCTAssertNil(SignInRequests.requester(of: "old", manifests: [copy.manifest]))
    }
}
