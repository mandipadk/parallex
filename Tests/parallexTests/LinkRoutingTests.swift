import XCTest
@testable import ParallexCore
import ParallexKit

final class LinkRoutingTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("links")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testReadsCustomSchemesAndSkipsSystemOnes() throws {
        let app = try Fixtures.makeApp(named: "Linky", bundleID: "com.fake.linky", in: tempDir, extraInfoKeys: [
            "CFBundleURLTypes": [
                ["CFBundleURLSchemes": ["Linky", "https"]],
                ["CFBundleURLSchemes": ["linky-auth", "mailto"]],
            ],
        ])
        XCTAssertEqual(LinkRouting.schemes(ofApp: app), ["linky", "linky-auth"])
        let plain = try Fixtures.makeApp(named: "Plain", bundleID: "com.fake.plain", in: tempDir)
        XCTAssertEqual(LinkRouting.schemes(ofApp: plain), [])
    }

    func testMostRecentlyActiveCandidateWins() {
        let original = LinkRouting.Candidate(pid: 100, name: "App (original)", isInstance: false)
        let work = LinkRouting.Candidate(pid: 200, name: "App Work", isInstance: true)
        XCTAssertEqual(LinkRouting.mostRecent([original, work], history: ["100": 10, "200": 20]), work)
        XCTAssertEqual(LinkRouting.mostRecent([original, work], history: ["100": 30, "200": 20]), original)
        XCTAssertNil(LinkRouting.mostRecent([original, work], history: [:]), "no history → ask")
    }

    func testActivationHistoryIsRecordedAndBounded() {
        for pid in 1...80 {
            LinkRouting.recordActivation(pid: pid_t(pid), at: Date(timeIntervalSince1970: Double(pid)))
        }
        let history = LinkRouting.loadHistory()
        XCTAssertEqual(history.count, 64)
        XCTAssertNotNil(history["80"])
        XCTAssertNil(history["1"])
    }

    func testConfigurationRoundTrips() throws {
        var config = LinkRouting.Configuration()
        config.enabled = true
        config.schemes = ["linky": "/Applications/Linky.app"]
        try LinkRouting.save(config)
        XCTAssertEqual(LinkRouting.loadConfiguration(), config)
    }

    func testEachRegistryGetsItsOwnRouter() {
        // PARALLEX_HOME is set in setUp: a development registry.
        XCTAssertTrue(LinkRouting.routerBundleID.hasPrefix("com.parallex.links.r"))
        let first = LinkRouting.routerBundleID
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("other").path, 1)
        XCTAssertNotEqual(LinkRouting.routerBundleID, first)
    }

    func testParallexBundlesAreNeverTheOriginalHandler() throws {
        let router = try Fixtures.makeApp(named: "Router", bundleID: "com.parallex.links.rabc", in: tempDir)
        let copy = try Fixtures.makeApp(named: "Copy", bundleID: "com.parallex.instance.work", in: tempDir)
        let real = try Fixtures.makeApp(named: "Real", bundleID: "com.fake.real", in: tempDir)
        XCTAssertTrue(LinkRouting.isParallexBundle(router))
        XCTAssertTrue(LinkRouting.isParallexBundle(copy))
        XCTAssertFalse(LinkRouting.isParallexBundle(real))
    }

    func testInheritedIsolationRule() {
        let root = "/private/tmp/fakehome/Library/Application Support/Parallex/instances"
        XCTAssertTrue(InheritedIsolation.matches(key: "PARALLEX_INSTANCE", value: "work", instancesRoot: root))
        XCTAssertTrue(InheritedIsolation.matches(key: "CODEX_HOME", value: "\(root)/work/codex-home", instancesRoot: root))
        XCTAssertTrue(InheritedIsolation.matches(key: "HOME", value: "\(root)/work/home", instancesRoot: root))
        XCTAssertFalse(InheritedIsolation.matches(key: "PATH", value: "/bin:\(root)/work/bin", instancesRoot: root))
        XCTAssertFalse(InheritedIsolation.matches(key: "HOME", value: "/private/tmp/fakehome", instancesRoot: root))
    }
}
