import XCTest
@testable import ParallexCore
import ParallexKit

final class AppCatalogTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("catalog")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
        setenv("PARALLEX_LAUNCHER", Fixtures.launcherBinary.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        unsetenv("PARALLEX_LAUNCHER")
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testClassifiesAndOrdersInstalledApps() throws {
        let apps = tempDir.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try Fixtures.makeApp(named: "Zeta Native", bundleID: "com.fake.zeta", in: apps)
        try Fixtures.makeApp(named: "Alpha Electron", bundleID: "com.fake.alpha", in: apps, electron: true)
        try Fixtures.makeApp(named: "Claude", bundleID: "com.anthropic.claudefordesktop", in: apps, electron: true)
        try Fixtures.makeApp(named: "Notes", bundleID: "com.apple.Notes", in: apps)
        // Parallex's own bundles never show up.
        try Fixtures.makeApp(named: "Router", bundleID: "com.parallex.links", in: apps)
        try Fixtures.makeApp(named: "Wrapped", bundleID: "com.parallex.instance.x", in: apps,
                             extraInfoKeys: [ParallexConfig.rootKey: ["Slug": "x"]])

        let catalog = AppCatalog.scan(directories: [apps])
        // Best fit first; apps with a tuned recipe lead their tier.
        XCTAssertEqual(catalog.map(\.name), ["Claude", "Alpha Electron", "Zeta Native", "Notes"])
        XCTAssertEqual(catalog.map(\.fit), [.great, .great, .ownIdentity, .unsupported])
        XCTAssertFalse(catalog[1].recommendsClone)
        XCTAssertTrue(catalog[2].recommendsClone)
    }

    /// Sign a fixture app ad hoc with these entitlements (signing works with
    /// any entitlements; only launching would fail).
    private func sign(_ app: URL, entitlements: [String: Any]) throws {
        let file = tempDir.appendingPathComponent("\(UUID().uuidString).plist")
        try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: file)
        try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", file.path, app.path])
    }

    /// The catalog says what a copy loses before one is made, and puts apps
    /// that install parts of themselves into macOS in their own tier.
    func testSaysWhatACopyCantDo() throws {
        let apps = tempDir.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let messenger = try Fixtures.makeApp(named: "Messenger", bundleID: "com.fake.messenger", in: apps, machOExecutable: true)
        try sign(messenger, entitlements: [
            "aps-environment": "production",
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.applesignin": ["Default"],
            "com.apple.developer.associated-domains": ["applinks:messenger.example"],
        ])
        let vpn = try Fixtures.makeApp(named: "Tunnel", bundleID: "com.fake.tunnel", in: apps, machOExecutable: true)
        let sysext = vpn.appendingPathComponent("Contents/Library/SystemExtensions/com.fake.tunnel.net.systemextension")
        try FileManager.default.createDirectory(at: sysext, withIntermediateDirectories: true)
        try sign(vpn, entitlements: ["com.apple.developer.networking.networkextension": ["packet-tunnel-provider"]])
        try Fixtures.makeApp(named: "Plain", bundleID: "com.fake.plain", in: apps, machOExecutable: true)

        let catalog = Dictionary(uniqueKeysWithValues: AppCatalog.scan(directories: [apps]).map { ($0.name, $0) })
        XCTAssertEqual(catalog["Messenger"]?.fit, .ownIdentity)
        XCTAssertEqual(catalog["Messenger"]?.cautions, [
            "No iCloud sync", "No push notifications", "No Sign in with Apple", "Its web links open the original",
        ])
        XCTAssertEqual(catalog["Tunnel"]?.fit, .systemParts)
        XCTAssertEqual(catalog["Tunnel"]?.recommendsClone, true, "still possible, just partial")
        XCTAssertEqual(catalog["Tunnel"]?.cautions, [], "the tier already says it")
        XCTAssertEqual(catalog["Plain"]?.cautions, [])
        // The create flow explains the same things at length.
        let notes = AppCloner.assess(try AppInspector.inspect(messenger)).notes.joined(separator: "\n")
        XCTAssertTrue(notes.contains("Sign in with Apple won't work in the copy"))
        XCTAssertTrue(AppCloner.assess(try AppInspector.inspect(vpn)).notes.contains { $0.contains("system extension") })
    }

    /// "Verified here" comes only from a check that saw the instance use its
    /// own files, is per app version, and goes away when a check finds a leak.
    func testVerifiedOnlyByARealCleanCheck() throws {
        let apps = tempDir.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let target = try Fixtures.makeApp(named: "Checked", bundleID: "com.fake.checked", in: apps, electron: true)
        let manifest = try InstanceCreator.create(
            CreateRequest(appReference: target.path, name: "Checked Work", outputDirectory: tempDir.appendingPathComponent("out")),
            builderOptions: BundleBuilder.Options(registerWithLaunchServices: false)
        ).manifest
        func verified() -> Bool { AppCatalog.scan(directories: [apps]).first { $0.name == "Checked" }?.verified == true }
        func report(_ findings: [IsolationReport.Finding]) -> IsolationReport {
            IsolationReport(processCount: 1, fileCount: findings.count, findings: findings)
        }
        let own = IsolationReport.Finding(path: "/x/instances/checked-work/data/db", category: .isolated, reason: "")
        let leak = IsolationReport.Finding(path: tempDir.appendingPathComponent("elsewhere/Checked/db").path, category: .leak, reason: "")

        XCTAssertFalse(verified())
        Verification.record(manifest, report: report([]))
        XCTAssertFalse(verified(), "nothing seen is no evidence")
        Verification.record(manifest, report: report([own]))
        XCTAssertTrue(verified())
        Verification.record(manifest, report: report([own, leak]))
        XCTAssertFalse(verified(), "a leak takes it back")

        // An instance with its isolation turned down proves nothing.
        var launchOnly = manifest
        launchOnly.mode = .launchOnly
        Verification.record(launchOnly, report: report([own]))
        XCTAssertFalse(verified())

        Verification.record(manifest, report: report([own]))
        XCTAssertTrue(verified())
        // A new version of the app hasn't been checked yet.
        let plist = target.appendingPathComponent("Contents/Info.plist")
        let info = try XCTUnwrap(NSMutableDictionary(contentsOf: plist))
        info["CFBundleShortVersionString"] = "9.9"
        info.write(to: plist, atomically: true)
        XCTAssertFalse(verified())
    }

    /// The name the catalog shows works wherever an app is named, even when
    /// the bundle's file is called something else.
    func testFindsAppsByTheirDisplayedName() throws {
        let apps = tempDir.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let editor = try Fixtures.makeApp(named: "Big Editor", bundleID: "com.fake.bigeditor", in: apps,
                                          extraInfoKeys: ["CFBundleName": "Code"])
        try Fixtures.makeApp(named: "A Code Work", bundleID: "com.parallex.instance.code-work", in: apps,
                             extraInfoKeys: ["CFBundleName": "Code", ParallexConfig.rootKey: ["Slug": "code-work"]])
        XCTAssertEqual(AppResolver.locate(displayName: "code", directories: [apps])?.lastPathComponent, editor.lastPathComponent)
        XCTAssertNil(AppResolver.locate(displayName: "Nothing", directories: [apps]))
    }

    func testMetadataChangesSaveWithoutRebuilding() throws {
        let outDir = tempDir.appendingPathComponent("out")
        let target = try Fixtures.makeApp(named: "Meta", bundleID: "com.fake.meta", in: tempDir, electron: true)
        let created = try InstanceCreator.create(
            CreateRequest(appReference: target.path, name: "Meta Work", outputDirectory: outDir),
            builderOptions: BundleBuilder.Options(registerWithLaunchServices: false)
        )
        let original = created.manifest.effectiveSettings

        var launchOnly = original
        launchOnly.openAtLaunch = true
        launchOnly.menuBarIcon = true
        launchOnly.badgeColorHex = "#30D158" // no badge: color is bookkeeping
        XCTAssertFalse(original.requiresRebuild(toReach: launchOnly))
        let saved = try InstanceCreator.saveSettings(launchOnly, for: created.manifest)
        XCTAssertEqual(InstanceStore.load(slug: "meta-work")?.settings?.openAtLaunch, true)
        XCTAssertEqual(InstanceStore.load(slug: "meta-work")?.settings?.menuBarIcon, true, "a menu bar icon needs no rebuild")
        XCTAssertEqual(saved.colorHex, "#30D158")

        var badged = launchOnly
        badged.badgeText = "W"
        XCTAssertTrue(launchOnly.requiresRebuild(toReach: badged))
        XCTAssertThrowsError(try InstanceCreator.saveSettings(badged, for: saved))
    }
}
