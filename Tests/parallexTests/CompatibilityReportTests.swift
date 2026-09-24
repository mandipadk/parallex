import XCTest
@testable import ParallexCore
import ParallexKit

final class CompatibilityReportTests: XCTestCase {
    private func manifest(target: String = "/Applications/This & That.app", clone: Bool = true, web: String? = nil) -> InstanceManifest {
        var settings = InstanceSettings()
        settings.webURL = web
        return InstanceManifest(
            name: "Client Acme — private",
            slug: "client-acme",
            bundleIdentifier: "com.parallex.instance.client-acme",
            targetApp: target,
            targetBinary: target + "/Contents/MacOS/app",
            wrapperPath: "/Volumes/Work/Applications/Client Acme.app",
            mode: .home,
            preset: nil,
            arguments: [],
            environment: [:],
            homeSymlinks: nil,
            createdAt: Date(),
            parallexVersion: ParallexConfig.version,
            targetBundleID: "com.example.thisandthat",
            settings: settings,
            clone: clone ? .init(bundleIdentifier: "com.parallex.instance.client-acme", sourceVersion: "4.2 (4.2)", usesLauncher: true) : nil,
            redirectedHome: clone ? "/Volumes/Work/Parallex/instances/client-acme/home" : nil
        )
    }

    func testSaysWhatItIsAndNothingPersonal() {
        let verified = ["com.example.thisandthat": Verification.Record(version: "4.2 (4.2)", date: Date(timeIntervalSince1970: 1_790_000_000), copy: true)]
        let facts = CompatibilityReport.facts(for: manifest(), verified: verified, system: "26.1 (arm64)")
        XCTAssertEqual(facts, """
            App: This & That 4.2 (com.example.thisandthat)
            Made as: own-identity copy, separate Library, separate hidden folders
            Isolation check: passed (4.2, 2026-09-21)
            Parallex: \(ParallexConfig.version)
            macOS: 26.1 (arm64)
            """)
        XCTAssertFalse(facts.contains("Acme"))
        XCTAssertFalse(facts.contains("/Volumes"))

        let web = CompatibilityReport.facts(for: manifest(clone: true, web: "https://teams.microsoft.com/v2/"), verified: [:], system: "26.1 (arm64)")
        XCTAssertTrue(web.hasPrefix("Site: teams.microsoft.com\nMade as: website"))
    }

    func testTheLinkCarriesEverything() throws {
        let url = CompatibilityReport.url(for: manifest(), facts: "App: This & That 4.2\nMade as: a + b = c")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(items.first { $0.name == "template" }?.value, "compatibility.yml")
        XCTAssertEqual(items.first { $0.name == "title" }?.value, "This & That: ")
        XCTAssertEqual(items.first { $0.name == "setup" }?.value, "App: This & That 4.2\nMade as: a + b = c")
        XCTAssertEqual(items.count, 3)
    }

    /// The form the link fills in has the fields it names.
    func testTheFormHasTheFields() throws {
        let form = try String(contentsOf: Fixtures.repositoryRoot.appendingPathComponent(".github/ISSUE_TEMPLATE/compatibility.yml"), encoding: .utf8)
        XCTAssertTrue(form.contains("id: setup"))
        XCTAssertEqual(CompatibilityReport.template, "compatibility.yml")
    }
}
