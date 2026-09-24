import AppKit
import XCTest
@testable import ParallexCore
import ParallexKit

/// Web instances: a website as an app of its own, made as an own-identity
/// copy of Parallex Web.
final class WebInstanceTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("web-instance")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
        setenv("PARALLEX_LAUNCHER", Fixtures.launcherBinary.path, 1)
        setenv("PARALLEX_HOME_LIBRARY", Fixtures.homeLibrary.path, 1)
        setenv("PARALLEX_WEB_SHELL", Fixtures.productsDirectory.appendingPathComponent("parallex-web").path, 1)
        outDir = tempDir.appendingPathComponent("apps")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for variable in ["PARALLEX_HOME", "PARALLEX_LAUNCHER", "PARALLEX_HOME_LIBRARY", "PARALLEX_WEB_SHELL"] {
            unsetenv(variable)
        }
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeWeb(_ address: String, name: String? = nil) throws -> CreateResult {
        var request = CreateRequest(appReference: "", name: name, outputDirectory: outDir)
        request.webURL = address
        return try InstanceCreator.create(request, builderOptions: options)
    }

    func testAWebInstanceIsAnAppOfItsOwn() throws {
        let result = try makeWeb("example.com/inbox")
        let manifest = result.manifest
        XCTAssertTrue(manifest.isWeb)
        XCTAssertEqual(manifest.name, "Example")
        XCTAssertEqual(manifest.targetDisplayName, "example.com")
        XCTAssertEqual(manifest.bundleIdentifier, "com.parallex.instance.example")
        XCTAssertNotNil(manifest.clone, "its own identity")
        XCTAssertNotNil(manifest.redirectedHome, "its own Library, where its website data lives")
        XCTAssertNotNil(manifest.keychainSuffix)

        let plist = try XCTUnwrap(NSDictionary(contentsOf: result.wrapperURL.appendingPathComponent("Contents/Info.plist")))
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.parallex.instance.example")
        let config = try XCTUnwrap(plist[ParallexConfig.rootKey] as? [String: Any])
        XCTAssertEqual((config[ParallexConfig.Key.environment] as? [String: String])?[WebShell.urlVariable], "https://example.com/inbox")
        XCTAssertEqual(config[ParallexConfig.Key.builtWith] as? String, ParallexConfig.version)
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: result.wrapperURL.appendingPathComponent("Contents/MacOS/Parallex Web").path
        ))
        XCTAssertEqual(InstanceStatus.check(manifest).problems, [])
        XCTAssertNoThrow(try Shell.run("/usr/bin/codesign", ["--verify", "--deep", result.wrapperURL.path]))

        // A rebuild keeps the site.
        let rebuilt = try InstanceCreator.update(manifest, InstanceUpdate(), builderOptions: options).manifest
        XCTAssertEqual(rebuilt.webURL?.absoluteString, "https://example.com/inbox")
    }

    /// The site's icon (here, its letter tile) becomes the app's; and the
    /// address can change later, like any other setting.
    func testWearsItsIconAndMoves() throws {
        var request = CreateRequest(appReference: "", outputDirectory: outDir)
        request.webURL = "example.com"
        request.customIcon = try XCTUnwrap(WebIcon.monogram(for: "Example", colorHex: "#1F7AE0"))
        let result = try InstanceCreator.create(request, builderOptions: options)
        let contents = result.wrapperURL.appendingPathComponent("Contents")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")))
        let iconFile = try XCTUnwrap(plist["CFBundleIconFile"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: contents.appendingPathComponent("Resources/\(iconFile).icns").path))

        var settings = result.manifest.effectiveSettings
        settings.webURL = "https://example.org/"
        let moved = try InstanceCreator.update(result.manifest, InstanceUpdate(settings: settings), builderOptions: options)
        XCTAssertEqual(moved.manifest.webURL?.absoluteString, "https://example.org/")
        XCTAssertEqual(moved.manifest.targetDisplayName, "example.org")
        let config = try XCTUnwrap(NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist"))?[ParallexConfig.rootKey] as? [String: Any])
        XCTAssertEqual((config[ParallexConfig.Key.environment] as? [String: String])?[WebShell.urlVariable], "https://example.org/")
        XCTAssertNotNil(NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist"))?["CFBundleIconFile"], "keeps its icon")
    }

    /// A second one of a site, or one next to the app of the same name,
    /// gets a name of its own; a duplicate still shows the site; and one
    /// exported here imports again.
    func testNamesDuplicatesAndArchives() throws {
        let first = try makeWeb("https://web.whatsapp.com")
        XCTAssertEqual(first.manifest.name, "WhatsApp")
        XCTAssertEqual(try makeWeb("web.whatsapp.com").manifest.name, "WhatsApp Web")
        XCTAssertEqual(WebShell.freeName(for: URL(string: "https://web.whatsapp.com")!, outputDirectory: outDir), "WhatsApp Web 2")

        let copy = try InstanceCreator.duplicate(first.manifest, includeData: false, builderOptions: options)
        XCTAssertEqual(copy.manifest.webURL?.absoluteString, "https://web.whatsapp.com")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: copy.wrapperURL.appendingPathComponent("Contents/Info.plist")))
        let config = try XCTUnwrap(plist[ParallexConfig.rootKey] as? [String: Any])
        XCTAssertEqual((config[ParallexConfig.Key.environment] as? [String: String])?[WebShell.urlVariable], "https://web.whatsapp.com")

        let archive = tempDir.appendingPathComponent("whatsapp.parallex")
        _ = try InstanceArchive.export(first.manifest, to: archive)
        let imported = try InstanceArchive.import(from: archive, outputDirectory: outDir, builderOptions: options)
        XCTAssertEqual(imported.manifest.webURL?.absoluteString, "https://web.whatsapp.com")
        XCTAssertTrue(imported.manifest.isWeb)
    }

    func testOnlyWebAddresses() {
        XCTAssertEqual(WebShell.normalizedURL("HTTPS://Web.WhatsApp.com/Path")?.absoluteString, "https://web.whatsapp.com/Path")
        for bad in ["ftp://example.com", "not a site", "file:///etc/passwd", "javascript:alert(1)", "https://"] {
            XCTAssertThrowsError(try makeWeb(bad), bad)
        }
        XCTAssertEqual(WebShell.normalizedURL("web.whatsapp.com")?.absoluteString, "https://web.whatsapp.com")
        XCTAssertEqual(WebShell.suggestedName(for: URL(string: "https://web.whatsapp.com")!), "WhatsApp")
        XCTAssertEqual(WebShell.suggestedName(for: URL(string: "https://app.linear.app")!), "Linear")
    }

    /// Next to an app of the same name, a web instance says it's the web one.
    func testNamedAroundTheAppOfTheSameName() throws {
        try FileManager.default.createDirectory(at: outDir.appendingPathComponent("WhatsApp.app"), withIntermediateDirectories: true)
        XCTAssertEqual(try makeWeb("https://web.whatsapp.com").manifest.name, "WhatsApp Web")
    }

    /// A new Parallex Web (a different binary) makes a new template, which
    /// is what brings it to every web instance.
    func testTheTemplateFollowsTheBinary() throws {
        let binary = tempDir.appendingPathComponent("parallex-web")
        try FileManager.default.copyItem(at: Fixtures.productsDirectory.appendingPathComponent("parallex-web"), to: binary)
        setenv("PARALLEX_WEB_SHELL", binary.path, 1)
        let template = try WebShell.templateApp()
        let first = NSDictionary(contentsOf: template.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String
        XCTAssertEqual(try WebShell.templateApp(), template)
        try FileManager.default.removeItem(at: binary)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: binary)
        _ = try WebShell.templateApp()
        let second = NSDictionary(contentsOf: template.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String
        XCTAssertNotEqual(first, second)
    }

    /// The whole thing, with WebKit: a page's unread count becomes the Dock
    /// badge, its notifications reach the app, and a link to another site
    /// is handed to your browser. Quiet mode: no window, no focus, nothing
    /// actually posted or opened.
    func testASiteBehavesLikeAnApp() throws {
        let site = tempDir.appendingPathComponent("site")
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try """
            <!doctype html><title>(3) Probe</title>
            <script>
              setTimeout(() => {
                new Notification("Hello", { body: "from the page" });
                document.title = "(5) Probe";
                window.open("https://example.com/elsewhere");
              }, 400);
              // An embedded frame (an ad, say) can't notify as the app or
              // hand links to other apps; nobody gets files or shares.
              setTimeout(() => {
                const frame = document.createElement("iframe");
                frame.srcdoc = "<script>window.webkit.messageHandlers.parallex.postMessage("
                  + "{type: 'notify', id: 'spoof', title: 'Spoof'}); location.href = 'mailto:x@example.com';<\\/script>";
                document.body.appendChild(frame);
              }, 700);
              setTimeout(() => { location.href = "smb://evil.example/share"; }, 1100);
            </script>
            """.write(to: site.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let port = Int.random(in: 20000...60000)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", site.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }
        for _ in 0..<50 where (try? Data(contentsOf: URL(string: "http://127.0.0.1:\(port)/")!)) == nil {
            Thread.sleep(forTimeInterval: 0.1)
        }

        let result = try makeWeb("http://127.0.0.1:\(port)/", name: "Probe Site")
        let log = tempDir.appendingPathComponent("web.log")
        let app = Process()
        app.executableURL = result.wrapperURL.appendingPathComponent("Contents/MacOS/parallex-launcher")
        var environment = ProcessInfo.processInfo.environment
        environment["PARALLEX_WEB_QUIET"] = "1"
        environment["PARALLEX_WEB_LOG"] = log.path
        environment["PARALLEX_LAUNCHER_NO_UI"] = "1"
        app.environment = environment
        try app.run()
        defer { app.terminate() }

        let expected = [
            "loaded http://127.0.0.1:\(port)/", "badge 3", "notify Hello", "badge 5", "external https://example.com/elsewhere",
            "blocked mailto:", "blocked smb:",
        ]
        var lines: [String] = []
        for _ in 0..<200 {
            lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            if expected.allSatisfy(lines.contains) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        for line in expected {
            XCTAssertTrue(lines.contains(line), "missing “\(line)” in \(lines)")
        }
        XCTAssertFalse(lines.contains("notify Spoof"), "a frame notified as the app")
    }

    func testFindsASitesIcons() {
        let html = """
            <link rel="icon" href="/favicon-16.png" sizes="16x16">
            <LINK REL="icon" HREF="https://cdn.example.com/icon-192.png" SIZES="192x192">
            <link rel='apple-touch-icon' href='/touch.png'>
            <link rel="icon" href="/logo.svg">
            <link rel="stylesheet" href="/site.css">
            """
        let found = WebIcon.declaredIcons(in: html, base: URL(string: "https://example.com/app/")!).map(\.absoluteString)
        XCTAssertEqual(found, ["https://example.com/touch.png", "https://cdn.example.com/icon-192.png", "https://example.com/favicon-16.png"])
        XCTAssertNotNil(WebIcon.monogram(for: "Probe", colorHex: "#0A84FF"))
    }

    /// Real sites, over the network: only on request (PARALLEX_LIVE_NETWORK=1).
    func testFetchesRealSitesIcons() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PARALLEX_LIVE_NETWORK"] == "1")
        for preset in WebShell.presets {
            let icon = WebIcon.fetch(for: URL(string: preset.url)!)
            let size = icon.flatMap { NSImage(contentsOf: $0) }?.size ?? .zero
            print("ICON \(preset.name): \(icon == nil ? "none" : "\(Int(size.width))x\(Int(size.height))")")
        }
    }
}
