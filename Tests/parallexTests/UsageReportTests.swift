import XCTest
@testable import ParallexCore
import ParallexKit

/// The opt-in usage report says what it should and nothing else.
final class UsageReportTests: XCTestCase {
    private func manifest(_ name: String, app: String, bundleID: String, clone: Bool = true, settings: InstanceSettings = InstanceSettings()) -> InstanceManifest {
        InstanceManifest(
            name: name, slug: Slug.make(name), bundleIdentifier: "com.parallex.instance.\(Slug.make(name))",
            targetApp: app, targetBinary: app + "/Contents/MacOS/x", wrapperPath: "/Applications/\(name).app",
            mode: .home, preset: nil, arguments: [], environment: [:], homeSymlinks: nil, createdAt: Date(),
            parallexVersion: ParallexConfig.version, targetBundleID: bundleID, settings: settings,
            clone: clone ? .init(bundleIdentifier: "com.parallex.instance.\(Slug.make(name))", sourceVersion: "4.43.1 (4.43.1)", usesLauncher: true) : nil
        )
    }

    func testNamesAppsFeaturesAndNothingPersonal() throws {
        var throwaway = InstanceSettings()
        throwaway.throwaway = true
        var whatsapp = InstanceSettings()
        whatsapp.webURL = "https://web.whatsapp.com"
        var intranet = InstanceSettings()
        intranet.webURL = "https://wiki.acme-corp.internal"
        let manifests = [
            manifest("Slack Client Acme", app: "/Applications/Slack.app", bundleID: "com.tinyspeck.slackmacgap"),
            manifest("Slack Two", app: "/Applications/Slack.app", bundleID: "com.tinyspeck.slackmacgap", settings: throwaway),
            manifest("Secret Tool", app: "/Volumes/Work/Projects/Secret Tool.app", bundleID: "com.acme.secret"),
            manifest("WhatsApp Web", app: "/x/Parallex Web.app", bundleID: "com.parallex.web", settings: whatsapp),
            manifest("Wiki", app: "/x/Parallex Web.app", bundleID: "com.parallex.web", settings: intranet),
        ]
        let quick = ["com.tinyspeck.slackmacgap": Compatibility.Record(quickExits: 2, lastQuickExit: Date(), version: "4.43.1")]
        let report = UsageReport.make(
            manifests: manifests, workspaces: [], links: LinkRouting.Configuration(), quickExits: quick, verified: [:]
        )
        XCTAssertEqual(report.apps.map(\.bundleID), ["com.tinyspeck.slackmacgap"], "an in-house app isn't named")
        XCTAssertEqual(report.otherApps, 1, "only counted")
        let slack = try XCTUnwrap(report.apps.first)
        XCTAssertEqual(slack.instances, 2)
        XCTAssertEqual(slack.kind, "copy")
        XCTAssertEqual(slack.appVersion, "4.43.1")
        XCTAssertTrue(slack.quitsAtLaunch)
        XCTAssertEqual(report.websites, ["web.whatsapp.com"])
        XCTAssertEqual(report.otherWebsites, 1, "other sites are counted, never named")
        XCTAssertEqual(report.features["throwaway"], 1)

        let json = String(decoding: report.json(), as: UTF8.self)
        for secret in ["Acme", "acme", "Secret", "Projects", "wiki", "Client"] {
            XCTAssertFalse(json.contains(secret), "“\(secret)” leaked into the report")
        }
    }
}
