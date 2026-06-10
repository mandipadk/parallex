import XCTest
@testable import ParallexCore

final class AppInspectorTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("inspector")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDetectsElectron() throws {
        let app = try Fixtures.makeApp(named: "FakeSlack", bundleID: "com.fake.slack", in: tempDir, electron: true)
        let info = try AppInspector.inspect(app)
        XCTAssertEqual(info.framework, .electron)
        XCTAssertFalse(info.isSandboxed)
        XCTAssertFalse(info.isParallexWrapper)
    }

    func testDetectsVSCodeFamily() throws {
        let app = try Fixtures.makeApp(
            named: "FakeCode", bundleID: "com.fake.code", in: tempDir,
            electron: true, productJSON: true
        )
        let info = try AppInspector.inspect(app)
        XCTAssertEqual(info.framework, .vscodeFamily)
    }

    func testDetectsFirefox() throws {
        let app = try Fixtures.makeApp(
            named: "FakeFox", bundleID: "org.fake.firefox", in: tempDir,
            applicationIni: true
        )
        let info = try AppInspector.inspect(app)
        XCTAssertEqual(info.framework, .firefox)
    }

    func testDetectsChromiumBrowserByBundleID() throws {
        let app = try Fixtures.makeApp(named: "FakeChrome", bundleID: "com.google.Chrome", in: tempDir)
        let info = try AppInspector.inspect(app)
        XCTAssertEqual(info.framework, .chromiumBrowser)

        let canary = try Fixtures.makeApp(named: "FakeCanary", bundleID: "com.google.Chrome.canary", in: tempDir)
        XCTAssertEqual(try AppInspector.inspect(canary).framework, .chromiumBrowser)
    }

    func testFallsBackToNative() throws {
        let app = try Fixtures.makeApp(named: "FakeNative", bundleID: "com.fake.native", in: tempDir)
        let info = try AppInspector.inspect(app)
        XCTAssertEqual(info.framework, .native)
    }

    func testRecognizesParallexWrappers() throws {
        let app = try Fixtures.makeApp(
            named: "FakeWrapper", bundleID: "com.parallex.instance.fake", in: tempDir,
            extraInfoKeys: ["Parallex": ["TargetBinary": "/bin/true"]]
        )
        let info = try AppInspector.inspect(app)
        XCTAssertTrue(info.isParallexWrapper)
    }

    func testRejectsNonApps() {
        XCTAssertThrowsError(try AppInspector.inspect(tempDir))
    }

    func testSandboxDetectionOnRealApps() throws {
        // Calculator ships sandboxed on every modern macOS; skip if absent.
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        guard FileManager.default.fileExists(atPath: calculator.path) else {
            throw XCTSkip("Calculator.app not present")
        }
        let info = try AppInspector.inspect(calculator)
        XCTAssertTrue(info.isSandboxed)
        XCTAssertNotNil(info.signingIdentifier)
    }

    func testUnsignedFixtureIsNotSandboxed() throws {
        let app = try Fixtures.makeApp(named: "FakePlain", bundleID: "com.fake.plain", in: tempDir)
        let info = try AppInspector.inspect(app)
        XCTAssertFalse(info.isSandboxed)
        XCTAssertNil(info.signingIdentifier)
    }
}
