import AppKit
import XCTest
@testable import ParallexCore

/// The whole path, with real processes and Launch Services, but without
/// touching your default browser: an instance opens a web link through
/// Parallex Links, which sends it to its workspace's browser; a site rule
/// and your usual browser work the same way. The "browsers" are small
/// background apps that note what they receive (and never keep focus).
final class WebRoutingEndToEndTests: XCTestCase {
    var tempDir: URL!
    var registered: [URL] = []

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("web-e2e")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
        setenv("PARALLEX_LAUNCHER", Fixtures.launcherBinary.path, 1)
    }

    override func tearDownWithError() throws {
        // The router stays running while web links are routed; it goes too.
        for app in registered + [LinkRouting.routerAppURL] {
            Shell.runAllowingFailure("/usr/bin/pkill", ["-f", app.path])
        }
        if let lsregister = BundleBuilder.lsregisterPath {
            for app in registered + [LinkRouting.routerAppURL] {
                Shell.runAllowingFailure(lsregister, ["-u", app.resolvingSymlinksInPath().path])
            }
        }
        unsetenv("PARALLEX_HOME")
        unsetenv("PARALLEX_LAUNCHER")
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A background app built from Objective-C source, with the log path it
    /// writes to in its environment.
    private func makeApp(_ name: String, bundleID: String, source: String, environment: [String: String]) throws -> URL {
        let app = tempDir.appendingPathComponent("\(name).app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let file = tempDir.appendingPathComponent("\(bundleID).m")
        try source.write(to: file, atomically: true, encoding: .utf8)
        try Shell.run("/usr/bin/clang", ["-fobjc-arc", "-framework", "Cocoa", file.path, "-o", macOS.appendingPathComponent(name).path])
        let plist: [String: Any] = [
            "CFBundleExecutable": name, "CFBundleIdentifier": bundleID, "CFBundleName": name,
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0", "LSUIElement": true,
            "LSEnvironment": environment,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        registered.append(app)
        return app
    }

    private let browserSource = """
        #import <Cocoa/Cocoa.h>
        @interface B : NSObject <NSApplicationDelegate> @end
        @implementation B
        - (void)applicationWillFinishLaunching:(NSNotification *)n {
            [[NSAppleEventManager sharedAppleEventManager] setEventHandler:self andSelector:@selector(get:reply:)
                forEventClass:kInternetEventClass andEventID:kAEGetURL];
        }
        - (void)applicationDidBecomeActive:(NSNotification *)n { [NSApp hide:nil]; }
        - (void)get:(NSAppleEventDescriptor *)e reply:(NSAppleEventDescriptor *)r {
            NSString *line = [[[e paramDescriptorForKeyword:keyDirectObject] stringValue] stringByAppendingString:@"\\n"];
            NSString *path = @(getenv("PROBE_LOG"));
            NSFileHandle *f = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!f) { [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
            [f seekToEndOfFile]; [f writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [f closeFile];
        }
        @end
        int main(void) { @autoreleasepool { B *b = [B new]; NSApplication *a = [NSApplication sharedApplication];
            a.delegate = b; [a run]; } }
        """

    private let senderSource = """
        #import <Cocoa/Cocoa.h>
        int main(void) { @autoreleasepool {
            NSURL *url = [NSURL URLWithString:@(getenv("SEND_URL"))];
            NSURL *router = [NSURL fileURLWithPath:@(getenv("ROUTER"))];
            NSWorkspaceOpenConfiguration *c = [NSWorkspaceOpenConfiguration configuration];
            c.activates = NO;
            [[NSWorkspace sharedWorkspace] openURLs:@[url] withApplicationAtURL:router configuration:c completionHandler:nil];
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:15]];
        } }
        """

    private func lines(_ file: URL, expecting count: Int) -> [String] {
        for _ in 0..<150 {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let lines = text.split(separator: "\n").map(String.init)
            if lines.count >= count { return lines }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func testWebLinksGoWhereTheirInstanceBelongs() throws {
        let workLog = tempDir.appendingPathComponent("work.log")
        let usualLog = tempDir.appendingPathComponent("usual.log")
        let workBrowser = try makeApp("WorkBrowser", bundleID: "dev.parallex.test.workbrowser",
                                      source: browserSource, environment: ["PROBE_LOG": workLog.path])
        let usualBrowser = try makeApp("UsualBrowser", bundleID: "dev.parallex.test.usualbrowser",
                                       source: browserSource, environment: ["PROBE_LOG": usualLog.path])

        try LinkRouting.buildRouterApp(
            binary: Fixtures.productsDirectory.appendingPathComponent("parallex-router"), schemes: WebRouting.schemes
        )
        let router = LinkRouting.routerAppURL
        var config = LinkRouting.Configuration()
        config.web = true
        config.previousBrowser = usualBrowser.path
        config.webRules = [WebLinkRule(domain: "northwind.com", target: .browser(path: workBrowser.path))]
        try LinkRouting.save(config)

        // An instance, in a workspace whose web links go to WorkBrowser, that
        // opens a link through the router the way any app would.
        let sender = try makeApp("Sendy", bundleID: "dev.parallex.test.sendy", source: senderSource, environment: [:])
        var request = CreateRequest(appReference: sender.path, name: "Sendy Work", mode: .launchOnly,
                                    outputDirectory: tempDir.appendingPathComponent("apps"))
        request.environment = ["SEND_URL": "https://example.com/from-work", "ROUTER": router.path]
        let instance = try InstanceCreator.create(request, builderOptions: BundleBuilder.Options(registerWithLaunchServices: false))
        registered.append(instance.wrapperURL)
        try WorkspaceStore.save([
            Workspace(name: "Work", members: [instance.manifest.slug], webLinks: .browser(path: workBrowser.path)),
        ])
        try Shell.run("/usr/bin/open", ["-g", instance.wrapperURL.path])
        XCTAssertEqual(lines(workLog, expecting: 1), ["https://example.com/from-work"], "the instance's link went to its workspace's browser")

        // From outside any instance: a site rule, then your usual browser.
        let done = expectation(description: "handed to the router")
        done.expectedFulfillmentCount = 2
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        for link in ["https://docs.northwind.com/page", "https://example.com/from-elsewhere"] {
            NSWorkspace.shared.open([URL(string: link)!], withApplicationAt: router, configuration: configuration) { _, _ in
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 20)
        XCTAssertEqual(lines(workLog, expecting: 2).last, "https://docs.northwind.com/page", "a site rule")
        XCTAssertEqual(lines(usualLog, expecting: 1), ["https://example.com/from-elsewhere"], "everything else: your usual browser")
    }
}
