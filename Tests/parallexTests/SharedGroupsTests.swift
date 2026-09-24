import XCTest
@testable import ParallexCore
import ParallexKit

/// Own-identity copies of sandboxed apps get their own app groups: renamed
/// group entitlements, and the mapping library that translates the app's
/// requests for its original groups.
final class SharedGroupsTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("groups")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
        setenv("PARALLEX_LAUNCHER", Fixtures.launcherBinary.path, 1)
        setenv("PARALLEX_GROUPS_LIBRARY", Fixtures.groupsLibrary.path, 1)
        outDir = tempDir.appendingPathComponent("apps", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        unsetenv("PARALLEX_LAUNCHER")
        unsetenv("PARALLEX_GROUPS_LIBRARY")
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func sign(_ url: URL, entitlements: [String: Any]) throws {
        let file = tempDir.appendingPathComponent("\(UUID().uuidString).plist")
        try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: file)
        _ = try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", file.path, url.path])
    }

    /// A sandboxed app with app groups and an XPC service that uses one.
    private func makeSandboxedApp() throws -> URL {
        let app = try Fixtures.makeApp(named: "Chatty", bundleID: "com.fake.chatty", in: tempDir, machOExecutable: true,
                                       extraInfoKeys: ["CFBundleShortVersionString": "1.0"])
        let service = app.appendingPathComponent("Contents/XPCServices/Sync.xpc/Contents")
        try FileManager.default.createDirectory(at: service.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: service.appendingPathComponent("MacOS/Sync").path)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.fake.chatty.sync", "CFBundleExecutable": "Sync", "CFBundlePackageType": "XPC!",
        ] as [String: Any], format: .xml, options: 0).write(to: service.appendingPathComponent("Info.plist"))
        let sandbox: [String: Any] = [
            "com.apple.security.app-sandbox": true,
            "com.apple.security.application-groups": ["group.com.fake.chatty.shared", "TEAMID.chatty"],
        ]
        try sign(service.deletingLastPathComponent(), entitlements: sandbox)
        try sign(app, entitlements: sandbox)
        return app
    }

    private func entitlements(of url: URL) -> [String: Any] {
        AppInspector.signingInfo(of: url).entitlements ?? [:]
    }

    func testCopyGetsItsOwnGroups() throws {
        let target = try makeSandboxedApp()
        var request = CreateRequest(appReference: target.path, name: "Chatty Work", outputDirectory: outDir)
        request.cloneApp = true
        let result = try InstanceCreator.create(request, builderOptions: options)
        let copy = result.wrapperURL

        let map = try XCTUnwrap(result.manifest.separatedGroups)
        XCTAssertEqual(Set(map.keys), ["group.com.fake.chatty.shared", "TEAMID.chatty"])
        let tag = try XCTUnwrap(InstanceCreator.groupTag(in: map["TEAMID.chatty"]!, slug: "chatty-work"))
        XCTAssertEqual(map["group.com.fake.chatty.shared"], "group.parallex.chatty-work-\(tag).com.fake.chatty.shared")
        XCTAssertEqual(map["TEAMID.chatty"], "group.parallex.chatty-work-\(tag).TEAMID.chatty")
        XCTAssertEqual(Set(entitlements(of: copy)["com.apple.security.application-groups"] as? [String] ?? []),
                       Set(map.values), "the copy is entitled to its own groups only")
        let serviceURL = copy.appendingPathComponent("Contents/XPCServices/Sync.xpc")
        XCTAssertEqual(Set(entitlements(of: serviceURL)["com.apple.security.application-groups"] as? [String] ?? []),
                       Set(map.values), "and so are its services")

        let info = try XCTUnwrap(NSDictionary(contentsOf: copy.appendingPathComponent("Contents/Info.plist")) as? [String: Any])
        let launchEnvironment = try XCTUnwrap(info["LSEnvironment"] as? [String: String])
        let library = copy.standardizedFileURL.appendingPathComponent(AppCloner.groupsLibraryPath)
        XCTAssertEqual(launchEnvironment["DYLD_INSERT_LIBRARIES"], library.path, "the library ships inside the copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.path))
        XCTAssertEqual(launchEnvironment["PARALLEX_GROUP_MAP"],
                       map.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";"))
        let service = try XCTUnwrap(NSDictionary(contentsOf: serviceURL.appendingPathComponent("Contents/Info.plist")) as? [String: Any])
        XCTAssertEqual(service["CFBundleIdentifier"] as? String, "com.parallex.instance.chatty-work.com.fake.chatty.sync")
        let serviceEnvironment = (service["XPCService"] as? [String: Any])?["EnvironmentVariables"] as? [String: String]
        XCTAssertEqual(serviceEnvironment?["PARALLEX_GROUP_MAP"], launchEnvironment["PARALLEX_GROUP_MAP"])
        XCTAssertEqual(launchEnvironment["PARALLEX_SERVICE_MAP"],
                       "com.fake.chatty.sync=com.parallex.instance.chatty-work.com.fake.chatty.sync")
        XCTAssertNoThrow(try Shell.run("/usr/bin/codesign", ["--verify", "--deep", copy.path]))

        // A rebuild keeps the copy's groups (its data lives there).
        let rebuilt = try InstanceCreator.update(result.manifest, InstanceUpdate(), builderOptions: options)
        XCTAssertEqual(rebuilt.manifest.separatedGroups, map)

        // A new instance with the same name gets groups of its own.
        _ = try InstanceRemover.remove(rebuilt.manifest, keepData: false)
        let again = try InstanceCreator.create(request, builderOptions: options)
        XCTAssertNotEqual(again.manifest.separatedGroups?["TEAMID.chatty"], map["TEAMID.chatty"])
    }

    func testTurningItOffKeepsTheOriginalsGroups() throws {
        let target = try makeSandboxedApp()
        var request = CreateRequest(appReference: target.path, name: "Chatty Shared", outputDirectory: outDir)
        request.cloneApp = true
        request.separateLibrary = false
        let result = try InstanceCreator.create(request, builderOptions: options)
        XCTAssertNil(result.manifest.separatedGroups)
        XCTAssertEqual(Set(entitlements(of: result.wrapperURL)["com.apple.security.application-groups"] as? [String] ?? []),
                       ["group.com.fake.chatty.shared", "TEAMID.chatty"])
    }

    func testCopiesMadeBefore012KeepSharingUntilTurnedOn() throws {
        let target = try makeSandboxedApp()
        var request = CreateRequest(appReference: target.path, name: "Chatty Old", outputDirectory: outDir)
        request.cloneApp = true
        var manifest = try InstanceCreator.create(request, builderOptions: options).manifest
        manifest.parallexVersion = "0.11.2"
        manifest.separatedGroups = nil
        manifest.settings?.separateLibrary = nil
        XCTAssertEqual(manifest.effectiveSettings.separateLibrary, false)
    }

    func testIsolationCheckKnowsTheCopysContainers() throws {
        let target = try makeSandboxedApp()
        var request = CreateRequest(appReference: target.path, name: "Chatty Check", outputDirectory: outDir)
        request.cloneApp = true
        let manifest = try InstanceCreator.create(request, builderOptions: options).manifest
        let home = "/Volumes/Test/home"
        let rules = IsolationCheck.Rules(manifest: manifest, home: home)
        XCTAssertEqual(rules.classify("\(home)/Library/Group Containers/group.com.fake.chatty.shared/db.sqlite")?.category, .leak)
        let renamed = try XCTUnwrap(manifest.separatedGroups?["group.com.fake.chatty.shared"])
        XCTAssertEqual(rules.classify("\(home)/Library/Group Containers/\(renamed)/db.sqlite")?.category, .isolated)
        XCTAssertEqual(rules.classify("\(home)/Library/Containers/com.parallex.instance.chatty-check.com.fake.chatty.sync/Data/x")?.category,
                       .isolated, "a renamed service's container is the copy's")
    }

    func testMappingLibraryTranslatesGroupLookups() throws {
        // A tiny program that asks for a group container and a group suite.
        let source = tempDir.appendingPathComponent("probe.m")
        try Data("""
        #import <Foundation/Foundation.h>
        int main(void) {
            NSURL *url = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@"group.com.fake.chatty.shared"];
            printf("%s\\n", url.lastPathComponent.UTF8String ?: "nil");
            // Connections must survive the library's hand-off (a lost retain
            // crashes the app on its first XPC connection).
            for (int i = 0; i < 50; i++) {
                @autoreleasepool {
                    NSXPCConnection *connection = [[NSXPCConnection alloc] initWithServiceName:@"com.fake.chatty.sync"];
                    [connection resume];
                    [connection invalidate];
                }
            }
            printf("ok\\n");
            return 0;
        }
        """.utf8).write(to: source)
        let probe = tempDir.appendingPathComponent("probe")
        _ = try Shell.run("/usr/bin/clang", ["-fobjc-arc", "-framework", "Foundation", source.path, "-o", probe.path])
        let process = Process()
        process.executableURL = probe
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_INSERT_LIBRARIES"] = Fixtures.groupsLibrary.path
        environment["PARALLEX_GROUP_MAP"] = "group.com.fake.chatty.shared=group.parallex.test.com.fake.chatty.shared"
        environment["PARALLEX_SERVICE_MAP"] = "com.fake.chatty.sync=com.parallex.instance.test.com.fake.chatty.sync"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let printed = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "no crash from the XPC hand-off")
        XCTAssertEqual(printed.split(separator: "\n").map(String.init),
                       ["group.parallex.test.com.fake.chatty.shared", "ok"])
    }
}
