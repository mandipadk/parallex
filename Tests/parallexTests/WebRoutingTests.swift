import XCTest
@testable import ParallexCore

/// Web links follow the instance they came from; site rules come first;
/// everything else goes to your usual browser.
final class WebRoutingTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("web")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    let work = WebLinkTarget.profile(browser: "/Applications/Google Chrome.app", directory: "Profile 1", name: "Work")
    let client = WebLinkTarget.instance(slug: "brave-northwind")

    func testSiteRulesThenTheSendersWorkspaceThenYourBrowser() {
        let workspaces = [
            Workspace(name: "Work", members: ["slack-work", "claude-work"], webLinks: work),
            Workspace(name: "Plain", members: ["claude-personal"]),
        ]
        let rules = [WebLinkRule(domain: "northwind.com", target: client)]
        let owner: (pid_t) -> String? = { [101: "slack-work", 202: "claude-personal"][$0] }
        func target(_ link: String, from sender: pid_t?) -> WebLinkTarget? {
            WebRouting.target(for: URL(string: link)!, sender: sender, rules: rules, workspaces: workspaces, instanceOwning: owner)
        }
        XCTAssertEqual(target("https://github.com/x", from: 101), work, "from Work Slack: Work's browser")
        XCTAssertEqual(target("https://app.northwind.com/y", from: 101), client, "a site rule wins")
        XCTAssertEqual(target("https://northwind.com", from: nil), client)
        XCTAssertNil(target("https://notnorthwind.com", from: nil), "only the domain and its subdomains")
        XCTAssertNil(target("https://github.com/x", from: 202), "a workspace without a browser: your usual one")
        XCTAssertNil(target("https://github.com/x", from: 999), "not from an instance")
        XCTAssertNil(target("https://github.com/x", from: nil))
    }

    func testTheMostSpecificRuleWins() {
        let rules = [
            WebLinkRule(domain: "northwind.com", target: client),
            WebLinkRule(domain: "https://docs.Northwind.com/", target: work),
        ]
        XCTAssertEqual(WebRouting.matchingRule(for: "docs.northwind.com", in: rules)?.target, work)
        XCTAssertEqual(WebRouting.matchingRule(for: "api.docs.northwind.com", in: rules)?.target, work)
        XCTAssertEqual(WebRouting.matchingRule(for: "northwind.com", in: rules)?.target, client)
        for (input, expected) in [("*.Example.com", "example.com"), ("www.example.com", "example.com"),
                                  ("https://example.com/path", "example.com"), ("example.com.", "example.com")] {
            XCTAssertEqual(WebRouting.normalizedDomain(input), expected, input)
        }
    }

    /// Electron opens links from helper processes: a helper's link belongs
    /// to its instance.
    func testALinkFromAHelperProcessBelongsToItsInstance() throws {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        helper.arguments = ["10"]
        try helper.run()
        defer { helper.terminate() }
        let running = ["work-app": getpid()]
        XCTAssertEqual(WebRouting.instance(owning: helper.processIdentifier, running: running), "work-app")
        XCTAssertEqual(WebRouting.instance(owning: getpid(), running: running), "work-app")
        XCTAssertNil(WebRouting.instance(owning: helper.processIdentifier, running: ["other": 1]))
    }

    func testReadsChromiumProfilesFromLocalState() throws {
        let localState = tempDir.appendingPathComponent("Local State")
        try Data("""
            {"profile": {"info_cache": {
                "Default": {"name": "Personal"},
                "Profile 1": {"name": "Work"},
                "../escape": {"name": "Nope"}
            }}}
            """.utf8).write(to: localState)
        let profiles = WebRouting.readProfiles(localState)
        XCTAssertEqual(profiles.map(\.directory), ["Default", "Profile 1"])
        XCTAssertEqual(profiles.map(\.name), ["Personal", "Work"])
        XCTAssertTrue(WebRouting.readProfiles(tempDir.appendingPathComponent("missing")).isEmpty)
    }

    func testTheRouterDeclaresWebLinksOnlyWhenRouting() {
        var config = LinkRouting.Configuration()
        config.enabled = true
        config.schemes = ["claude": "/Applications/Claude.app"]
        XCTAssertEqual(LinkRouting.routerSchemes(config), ["claude"])
        config.web = true
        XCTAssertEqual(LinkRouting.routerSchemes(config), ["claude", "http", "https"])
        config.enabled = false
        XCTAssertEqual(LinkRouting.routerSchemes(config), ["http", "https"])
    }

    /// Workspaces saved before web routing still load, and the new field
    /// round-trips.
    func testWorkspacesKeepTheirWebTarget() throws {
        let old = #"{"id":"6F1E8C2A-0A7B-4C1E-9E4B-2D2C8E1A9B10","name":"Work","members":["a"],"hidesOthers":false}"#
        let decoded = try JSONDecoder().decode(Workspace.self, from: Data(old.utf8))
        XCTAssertNil(decoded.webLinks)
        var edited = decoded
        edited.webLinks = work
        let again = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(again.webLinks, work)
    }

    func testTargetsByName() throws {
        let chrome = WebRouting.Browser(url: URL(fileURLWithPath: "/Applications/Google Chrome.app"), name: "Google Chrome", bundleID: "com.google.Chrome")
        let safari = WebRouting.Browser(url: URL(fileURLWithPath: "/Applications/Safari.app"), name: "Safari", bundleID: "com.apple.Safari")
        let profiles = [WebRouting.Profile(browser: chrome.url, browserName: chrome.name, directory: "Profile 1", name: "Work")]
        func resolve(_ text: String) throws -> WebLinkTarget? {
            try WebRouting.resolveTarget(text, manifests: [], browsers: [chrome, safari], profiles: profiles)
        }
        XCTAssertNil(try resolve("default"))
        XCTAssertEqual(try resolve("safari"), .browser(path: "/Applications/Safari.app"))
        XCTAssertEqual(try resolve("Chrome/Work"), profiles[0].target)
        XCTAssertEqual(try resolve("Google Chrome/Profile 1"), profiles[0].target)
        XCTAssertThrowsError(try resolve("Netscape"))

        // Instances by name, but only instances of browsers.
        func manifest(_ name: String, _ bundleID: String) -> InstanceManifest {
            InstanceManifest(
                name: name, slug: Slug.make(name), bundleIdentifier: "com.parallex.instance.x", targetApp: "/Applications/X.app",
                targetBinary: "/Applications/X.app/Contents/MacOS/X", wrapperPath: "/Applications/\(name).app", mode: .dataDir,
                preset: nil, arguments: [], environment: [:], homeSymlinks: nil, createdAt: Date(),
                parallexVersion: "0.14.0", targetBundleID: bundleID
            )
        }
        let manifests = [manifest("Chrome Work", "com.google.Chrome"), manifest("Slack Work", "com.tinyspeck.slackmacgap")]
        XCTAssertEqual(try WebRouting.resolveTarget("chrome work", manifests: manifests, browsers: [chrome], profiles: []),
                       .instance(slug: "chrome-work"))
        XCTAssertThrowsError(try WebRouting.resolveTarget("Slack Work", manifests: manifests, browsers: [chrome], profiles: []),
                             "not a browser: links would go nowhere, or loop")
    }
}
