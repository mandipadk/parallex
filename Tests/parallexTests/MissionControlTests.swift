import XCTest
@testable import ParallexCore
import ParallexKit

/// What an update check tells Parallex's server, and falling back to GitHub.
final class MissionControlTests: XCTestCase {
    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    func testEachCheckSaysWhatItsTheFirstOf() {
        let first = CheckActivity().periods(at: date("2026-09-24T15:00:00Z"), checkedBefore: false)
        XCTAssertEqual(first.periods, ["new", "day", "week", "month"])
        XCTAssertEqual(first.next, CheckActivity(day: "2026-09-24", week: "2026-W39", month: "2026-09"))

        let later = first.next.periods(at: date("2026-09-24T23:59:00Z"), checkedBefore: true)
        XCTAssertEqual(later.periods, [], "same (UTC) day: counted once")

        let tomorrow = first.next.periods(at: date("2026-09-25T15:00:00Z"), checkedBefore: true)
        XCTAssertEqual(tomorrow.periods, ["day"])

        let nextWeek = first.next.periods(at: date("2026-09-28T15:00:00Z"), checkedBefore: true)
        XCTAssertEqual(nextWeek.periods, ["day", "week"])

        let nextMonth = nextWeek.next.periods(at: date("2026-10-01T15:00:00Z"), checkedBefore: true)
        XCTAssertEqual(nextMonth.periods, ["day", "month"], "Thursday the 1st: same week as Monday the 28th")

        // Updated from a Parallex that checked before these records: not new.
        XCTAssertEqual(CheckActivity().periods(at: date("2026-09-24T15:00:00Z"), checkedBefore: true).periods,
                       ["day", "week", "month"])
    }

    func testHeadersSayNothingElse() {
        let headers = CheckActivity.headers(periods: ["day", "week"])
        XCTAssertEqual(headers.map(\.0), ["X-Parallex-Version", "X-Parallex-OS", "X-Parallex-Arch", "X-Parallex-Active"])
        XCTAssertEqual(headers[0].1, ParallexConfig.version)
        XCTAssertTrue(headers[1].1.range(of: #"^\d+\.\d+$"#, options: .regularExpression) != nil)
        XCTAssertTrue(["arm64", "x86_64"].contains(headers[2].1))
        XCTAssertEqual(headers[3].1, "day,week")

        let withBucket = CheckActivity.headers(periods: [], bucket: 42)
        XCTAssertEqual(withBucket.last?.0, "X-Parallex-Bucket")
        XCTAssertEqual(withBucket.last?.1, "42")
        XCTAssertTrue((0..<100).contains(CheckActivity.pickBucket()))
    }

    /// Parallex's server first; GitHub when it doesn't answer. Only the
    /// server hears the activity.
    func testFallsBackToGitHub() async throws {
        StubProtocol.answers = [
            "parallex.mandip.dev": (502, Data("down".utf8)),
            "api.github.com": (200, releaseJSON),
        ]
        StubProtocol.seen = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)

        let heard = Heard()
        let viaGitHub = try await UpdateFeed.fetchLatest(activity: ["day"], session: session) { heard.count += 1 }
        XCTAssertEqual(heard.count, 0, "the server didn't take it")
        XCTAssertEqual(viaGitHub.release.version, "0.9.0")
        XCTAssertFalse(viaGitHub.counted)
        XCTAssertEqual(StubProtocol.seen.map(\.host), ["parallex.mandip.dev", "api.github.com"])
        XCTAssertEqual(StubProtocol.seen[0].active, "day")
        XCTAssertNil(StubProtocol.seen[1].active, "GitHub isn't told")

        StubProtocol.answers["parallex.mandip.dev"] = (200, releaseJSON)
        StubProtocol.seen = []
        let viaServer = try await UpdateFeed.fetchLatest(activity: [], session: session) { heard.count += 1 }
        XCTAssertTrue(viaServer.counted)
        XCTAssertEqual(heard.count, 1)
        XCTAssertEqual(StubProtocol.seen.map(\.host), ["parallex.mandip.dev"])

        // Taken by the server but not readable: counted once all the same.
        StubProtocol.answers["parallex.mandip.dev"] = (200, Data("{}".utf8))
        StubProtocol.answers["api.github.com"] = (500, Data())
        do {
            _ = try await UpdateFeed.fetchLatest(activity: ["day"], session: session) { heard.count += 1 }
            XCTFail("nothing readable")
        } catch {}
        XCTAssertEqual(heard.count, 2)

        // Every release pulled: the server offers nothing, and GitHub (which
        // pulls don't reach) isn't asked instead.
        StubProtocol.answers["parallex.mandip.dev"] = (204, Data())
        StubProtocol.answers["api.github.com"] = (200, releaseJSON)
        StubProtocol.seen = []
        do {
            _ = try await UpdateFeed.fetchLatest(activity: [], session: session)
            XCTFail("nothing is offered")
        } catch {}
        XCTAssertEqual(StubProtocol.seen.map(\.host), ["parallex.mandip.dev"])
    }

    private var releaseJSON: Data {
        Data(#"{"tag_name":"v0.9.0","body":"","html_url":"https://github.com/mandipadk/parallex/releases/tag/v0.9.0","draft":false,"prerelease":false,"assets":[{"name":"Parallex-0.9.0.zip","browser_download_url":"https://example.com/a.zip","size":1},{"name":"Parallex-0.9.0.zip.sig","browser_download_url":"https://example.com/a.zip.sig","size":1}]}"#.utf8)
    }
}

final class Heard: @unchecked Sendable {
    var count = 0
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var answers: [String: (Int, Data)] = [:]
    nonisolated(unsafe) static var seen: [(host: String, active: String?)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.seen.append((host, request.value(forHTTPHeaderField: "X-Parallex-Active")))
        let (status, body) = Self.answers[host] ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
