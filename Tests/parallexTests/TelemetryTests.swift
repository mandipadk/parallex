import XCTest
@testable import ParallexCore
import ParallexKit

/// The daily usage report: what's kept until it's sent, what it holds, and
/// that saying no leaves nothing behind.
final class TelemetryTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("telemetry")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        ReportStub.handler = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCountsWhatHappensAndMergesLikeEvents() {
        Telemetry.setConsent(.shared)
        Telemetry.record("instance.created", ["kind": "copy", "result": "ok"])
        Telemetry.record("instance.created", ["kind": "copy", "result": "ok"])
        Telemetry.record("instance.created", ["kind": "copy", "result": "failed", "step": "build"])
        Telemetry.record("snapshot.restored", n: 3)
        Telemetry.record("snapshot.restored", version: "0.9.0")
        let report = Telemetry.make(manifests: [])
        let now = ParallexConfig.version
        XCTAssertEqual(report.schema, 2)
        XCTAssertEqual(Set(report.events), [
            Telemetry.Event(name: "instance.created", props: ["kind": "copy", "result": "ok"], n: 2, version: now),
            Telemetry.Event(name: "instance.created", props: ["kind": "copy", "result": "failed", "step": "build"], n: 1, version: now),
            Telemetry.Event(name: "snapshot.restored", props: [:], n: 3, version: now),
            Telemetry.Event(name: "snapshot.restored", props: [:], n: 1, version: "0.9.0"),
        ], "what happened before an update stays with the version it happened on")
    }

    func testNothingIsKeptBeforeItsSaidYesTo() {
        Telemetry.record("snapshot.restored")
        Telemetry.recordCrash(Telemetry.Crash(kind: "hang", frames: [], n: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Telemetry.pendingFile.path))
        Telemetry.setConsent(.shared)
        XCTAssertTrue(Telemetry.make(manifests: []).events.isEmpty, "nothing from before comes along")
    }

    func testDecliningKeepsNothingAndRecordsNothing() {
        Telemetry.setConsent(.shared)
        Telemetry.record("snapshot.restored")
        _ = Telemetry.install()
        Telemetry.setConsent(.declined)
        XCTAssertEqual(Telemetry.consent, .declined)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Telemetry.pendingFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Telemetry.installFile.path))
        Telemetry.record("snapshot.restored")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Telemetry.pendingFile.path))
    }

    func testUndecidedUntilChosen() {
        XCTAssertEqual(Telemetry.consent, .undecided)
        XCTAssertFalse(Telemetry.hasChosen)
        Telemetry.setConsent(.shared)
        XCTAssertEqual(Telemetry.consent, .shared)
        XCTAssertTrue(Telemetry.hasChosen)
    }

    func testInstallNumberIsRandomRenewedAndKeepsItsWeek() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z"))
        let first = Telemetry.install(now: start)
        XCTAssertNotNil(first.id.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression))
        XCTAssertEqual(first.since, "2026-W40")
        XCTAssertEqual(Telemetry.install(now: start.addingTimeInterval(100 * 86_400)), first)
        let renewed = Telemetry.install(now: start.addingTimeInterval(181 * 86_400))
        XCTAssertNotEqual(renewed.id, first.id)
        XCTAssertEqual(renewed.since, "2026-W40", "still counted with the week it started")
    }

    func testPreviewLeavesNoNumberBehind() {
        _ = Telemetry.make(manifests: [], preview: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Telemetry.installFile.path))
    }

    func testSendingClearsOnlyWhatWasSent() async throws {
        Telemetry.setConsent(.shared)
        Telemetry.record("snapshot.taken", ["reason": "manual"], n: 2)
        let report = Telemetry.make(manifests: [])
        // Meanwhile, more happens.
        Telemetry.record("snapshot.taken", ["reason": "manual"])
        Telemetry.record("snapshot.restored")
        var body: [String: Any]?
        ReportStub.handler = { request in
            body = request.httpBodyStream.flatMap { stream in
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    guard read > 0 else { break }
                    data.append(buffer, count: read)
                }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            return 204
        }
        try await Telemetry.send(report, session: ReportStub.session)
        XCTAssertEqual(body?["schema"] as? Int, 2)
        XCTAssertEqual(body?["install"] as? String, report.install)
        let next = Telemetry.make(manifests: [])
        XCTAssertEqual(Set(next.events), [
            Telemetry.Event(name: "snapshot.taken", props: ["reason": "manual"], n: 1, version: ParallexConfig.version),
            Telemetry.Event(name: "snapshot.restored", props: [:], n: 1, version: ParallexConfig.version),
        ])
    }

    func testAFailedSendKeepsEverything() async {
        Telemetry.setConsent(.shared)
        Telemetry.record("snapshot.restored")
        ReportStub.handler = { _ in 500 }
        let report = Telemetry.make(manifests: [])
        do {
            try await Telemetry.send(report, session: ReportStub.session)
            XCTFail("a 500 isn't taken")
        } catch {}
        XCTAssertEqual(Telemetry.make(manifests: []).events.first?.n, 1)
    }

    func testCrashKeepsOnlyParallexFramesTopFirst() throws {
        let tree = """
        {"callStackPerThread": true, "callStacks": [
          {"threadAttributed": false, "callStackRootFrames": [
            {"binaryName": "Parallex", "binaryUUID": "11111111-2222-3333-4444-555555555555", "offsetIntoBinaryTextSegment": 1, "subFrames": []}]},
          {"threadAttributed": true, "callStackRootFrames": [
            {"binaryName": "libsystem_kernel.dylib", "binaryUUID": "AAAAAAAA-2222-3333-4444-555555555555", "offsetIntoBinaryTextSegment": 99,
             "subFrames": [
              {"binaryName": "Parallex", "binaryUUID": "11111111-2222-3333-4444-555555555555", "offsetIntoBinaryTextSegment": 4660,
               "subFrames": [
                {"binaryName": "/Volumes/Work/Secret.app/Contents/MacOS/Secret", "binaryUUID": "BBBBBBBB-2222-3333-4444-555555555555", "offsetIntoBinaryTextSegment": 7,
                 "subFrames": [
                  {"binaryName": "libparallexhome.dylib", "binaryUUID": "CCCCCCCC-2222-3333-4444-555555555555", "offsetIntoBinaryTextSegment": 8}]}]}]}]}
        ]}
        """
        let crash = try XCTUnwrap(Telemetry.crash(kind: "crash", callStackTree: Data(tree.utf8), signal: 11, exceptionType: 1))
        XCTAssertEqual(crash.frames.map(\.binary), ["Parallex", "libparallexhome.dylib"])
        XCTAssertEqual(crash.frames.first?.offset, 4660)
        XCTAssertEqual(crash.signal, 11)

        let elsewhere = """
        {"callStacks": [{"threadAttributed": true, "callStackRootFrames": [
          {"binaryName": "AppKit", "binaryUUID": "AAAAAAAA-2222-3333-4444-555555555555", "offsetIntoBinaryTextSegment": 1}]}]}
        """
        XCTAssertNil(Telemetry.crash(kind: "hang", callStackTree: Data(elsewhere.utf8)), "not Parallex's to report")
    }

    func testCrashesMergeByWhereTheyHappened() async throws {
        Telemetry.setConsent(.shared)
        let frame = Telemetry.Frame(binary: "Parallex", uuid: "11111111-2222-3333-4444-555555555555", offset: 10)
        let crash = Telemetry.Crash(kind: "crash", signal: 11, exceptionType: 1, frames: [frame], n: 1)
        Telemetry.recordCrash(crash)
        Telemetry.recordCrash(crash)
        let report = Telemetry.make(manifests: [])
        XCTAssertEqual(report.crashes.count, 1)
        XCTAssertEqual(report.crashes.first?.n, 2)
        // The same crash again while the report is on its way: only it is
        // left for the next one.
        Telemetry.recordCrash(crash)
        ReportStub.handler = { _ in 204 }
        try await Telemetry.send(report, session: ReportStub.session)
        XCTAssertEqual(Telemetry.make(manifests: []).crashes.map(\.n), [1])
    }

    func testReportNamesKindsAndWellKnownAppsOnly() throws {
        let manifests = [
            manifest("Slack Work", app: "/Applications/Slack.app", bundleID: "com.tinyspeck.slackmacgap"),
            manifest("Secret Tool", app: "/Volumes/Work/Secret Tool.app", bundleID: "com.acme.secret"),
        ]
        let report = Telemetry.make(manifests: manifests, preview: true)
        XCTAssertTrue(report.gauges.contains(Telemetry.Gauge(name: "instances", props: ["kind": "copy"], value: 2)))
        XCTAssertTrue(report.gauges.contains { $0.name == "app" && $0.props["app"] == "com.tinyspeck.slackmacgap" })
        XCTAssertTrue(report.gauges.contains(Telemetry.Gauge(name: "app.other", props: [:], value: 1)))
        let json = String(decoding: Telemetry.json(report), as: UTF8.self)
        for secret in ["Secret", "acme", "Slack Work", "/Volumes", "/Applications"] {
            XCTAssertFalse(json.contains(secret), "\(secret) left the Mac")
        }
        XCTAssertEqual(Telemetry.appName(for: manifests[0]), "com.tinyspeck.slackmacgap")
        XCTAssertEqual(Telemetry.appName(for: manifests[1]), "other")
    }

    private func manifest(_ name: String, app: String, bundleID: String) -> InstanceManifest {
        InstanceManifest(
            name: name, slug: Slug.make(name), bundleIdentifier: "com.parallex.instance.\(Slug.make(name))",
            targetApp: app, targetBinary: app + "/Contents/MacOS/x", wrapperPath: "/Applications/\(name).app",
            mode: .home, preset: nil, arguments: [], environment: [:], homeSymlinks: nil, createdAt: Date(),
            parallexVersion: ParallexConfig.version, targetBundleID: bundleID, settings: InstanceSettings(),
            clone: .init(bundleIdentifier: "com.parallex.instance.\(Slug.make(name))", sourceVersion: "4.43.1 (4.43.1)", usesLauncher: true)
        )
    }
}

/// Answers the report's request without a network.
private final class ReportStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> Int)?

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReportStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status = Self.handler?(request) ?? 500
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
