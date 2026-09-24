import XCTest
@testable import ParallexCore
import ParallexKit

/// Own-identity copies of apps that aren't sandboxed keep their own
/// ~/Library: the copy loads the home-redirect library, and the app sees the
/// instance's home wherever macOS resolves "home" from the user account.
final class SeparateLibraryTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("library")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
        setenv("PARALLEX_LAUNCHER", Fixtures.launcherBinary.path, 1)
        setenv("PARALLEX_HOME_LIBRARY", Fixtures.homeLibrary.path, 1)
        outDir = tempDir.appendingPathComponent("apps", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        unsetenv("PARALLEX_LAUNCHER")
        unsetenv("PARALLEX_HOME_LIBRARY")
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Run a built instance through its launcher and read what the app saw.
    private func run(_ app: URL) throws -> [String] {
        let out = tempDir.appendingPathComponent("report-\(UUID().uuidString).txt")
        let process = Process()
        process.executableURL = app.appendingPathComponent("Contents/MacOS/parallex-launcher")
        var environment = ProcessInfo.processInfo.environment
        environment["FIXTURE_OUT"] = out.path
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: out.path) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return try String(contentsOf: out, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    func testCopyOfNativeAppSeesTheInstanceHome() throws {
        let target = try Fixtures.makeHomeReportingApp(named: "Homey", bundleID: "com.fake.homey", in: tempDir)
        var request = CreateRequest(appReference: target.path, name: "Homey Work", outputDirectory: outDir)
        request.cloneApp = true
        let result = try InstanceCreator.create(request, builderOptions: options)

        let home = Paths.instanceDir(slug: "homey-work").appendingPathComponent("home").path
        XCTAssertEqual(result.manifest.redirectedHome, home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Paths.homeLibrary.path), "the library is installed")
        let config = try XCTUnwrap(NSDictionary(contentsOf: result.wrapperURL.appendingPathComponent("Contents/Info.plist"))?[ParallexConfig.rootKey] as? [String: Any])
        XCTAssertEqual(config[ParallexConfig.Key.redirectLibrary] as? String, Paths.homeLibrary.path)

        let report = try run(result.wrapperURL)
        XCTAssertEqual(report[0], home, "NSHomeDirectory is the instance's home")
        XCTAssertEqual(report[1], home + "/Library/Application Support")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/Library/Application Support/Homey"),
                      "what the app writes lands in the instance")
        let realSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Homey")
        XCTAssertFalse(FileManager.default.fileExists(atPath: realSupport.path), "nothing in the real Library")
        // Shared folders are still reachable through the instance home.
        let documents = URL(fileURLWithPath: home).appendingPathComponent("Documents")
        XCTAssertEqual(try? FileManager.default.destinationOfSymbolicLink(atPath: documents.path),
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents").path)
    }

    func testTurningSeparationOffUsesTheRealLibrary() throws {
        let target = try Fixtures.makeHomeReportingApp(named: "Plain", bundleID: "com.fake.plain", in: tempDir)
        var request = CreateRequest(appReference: target.path, name: "Plain Work", outputDirectory: outDir)
        request.cloneApp = true
        let created = try InstanceCreator.create(request, builderOptions: options)
        var settings = created.manifest.effectiveSettings
        settings.separateLibrary = false
        let rebuilt = try InstanceCreator.update(created.manifest, InstanceUpdate(settings: settings), builderOptions: options)

        XCTAssertNil(rebuilt.manifest.redirectedHome)
        let config = try XCTUnwrap(NSDictionary(contentsOf: rebuilt.wrapperURL.appendingPathComponent("Contents/Info.plist"))?[ParallexConfig.rootKey] as? [String: Any])
        XCTAssertNil(config[ParallexConfig.Key.redirectHome])
        let report = try run(rebuilt.wrapperURL)
        XCTAssertEqual(report[0], FileManager.default.homeDirectoryForCurrentUser.path)
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Plain"))
    }

    func testCopiesMadeBeforeSeparationExistedKeepTheirLibrary() throws {
        let target = try Fixtures.makeHomeReportingApp(named: "Oldie", bundleID: "com.fake.oldie", in: tempDir)
        var request = CreateRequest(appReference: target.path, name: "Oldie Work", outputDirectory: outDir)
        request.cloneApp = true
        var manifest = try InstanceCreator.create(request, builderOptions: options).manifest
        // As a 0.8 instance would have been recorded.
        manifest.parallexVersion = "0.8.0"
        manifest.redirectedHome = nil
        manifest.settings?.separateLibrary = nil
        XCTAssertEqual(manifest.effectiveSettings.separateLibrary, false, "a routine rebuild must not move its data")
        let rebuilt = try InstanceCreator.update(manifest, InstanceUpdate(), builderOptions: options)
        XCTAssertNil(rebuilt.manifest.redirectedHome)
    }

    /// Copies made before 0.13 shared the app's hidden folders; a routine
    /// rebuild keeps that (a VS Code copy keeps its extensions) until the
    /// user turns separation on. New copies separate them.
    func testCopiesMadeBeforeHiddenFolderSeparationKeepSharing() throws {
        let target = try Fixtures.makeHomeReportingApp(named: "Hidey", bundleID: "com.fake.hidey", in: tempDir)
        var request = CreateRequest(appReference: target.path, name: "Hidey Work", mode: .launchOnly, outputDirectory: outDir)
        request.cloneApp = true
        let fresh = try InstanceCreator.create(request, builderOptions: options).manifest
        XCTAssertEqual(fresh.privateHomeItems?.first, ".hidey")
        XCTAssertNotNil(plistConfig(fresh)[ParallexConfig.Key.redirectPrivate])

        var old = fresh
        old.parallexVersion = "0.12.4"
        old.privateHomeItems = nil
        old.settings?.separateHiddenFolders = nil
        XCTAssertEqual(old.effectiveSettings.separateHiddenFolders, false)
        let rebuilt = try InstanceCreator.update(old, InstanceUpdate(), builderOptions: options).manifest
        XCTAssertNil(rebuilt.privateHomeItems)
        XCTAssertNotNil(rebuilt.redirectedHome, "its Library stays separate either way")
        XCTAssertNil(plistConfig(rebuilt)[ParallexConfig.Key.redirectPrivate])
        // A duplicate keeps the choice.
        let twin = try InstanceCreator.duplicate(rebuilt, builderOptions: options).manifest
        XCTAssertEqual(twin.effectiveSettings.separateHiddenFolders, false)
        XCTAssertNil(twin.privateHomeItems)

        var turnedOn = rebuilt.effectiveSettings
        turnedOn.separateHiddenFolders = true
        let separated = try InstanceCreator.update(rebuilt, InstanceUpdate(settings: turnedOn), builderOptions: options).manifest
        XCTAssertEqual(separated.privateHomeItems?.first, ".hidey")
    }

    private func plistConfig(_ manifest: InstanceManifest) -> [String: Any] {
        let plist = NSDictionary(contentsOf: URL(fileURLWithPath: manifest.wrapperPath).appendingPathComponent("Contents/Info.plist"))
        return plist?[ParallexConfig.rootKey] as? [String: Any] ?? [:]
    }

    func testWrappersAndSandboxedCopiesAreUnaffected() throws {
        let target = try Fixtures.makeHomeReportingApp(named: "Wrap", bundleID: "com.fake.wrap", in: tempDir)
        let result = try InstanceCreator.create(
            CreateRequest(appReference: target.path, name: "Wrap Work", outputDirectory: outDir), builderOptions: options
        )
        XCTAssertNil(result.manifest.redirectedHome, "a plain wrapper can't load the library (hardened apps)")
    }

    func testRemovalTakesTheCopysPreferencesAlong() throws {
        let target = try Fixtures.makeHomeReportingApp(named: "Prefy", bundleID: "com.fake.prefy", in: tempDir)
        var request = CreateRequest(appReference: target.path, name: "Prefy Test \(UUID().uuidString.prefix(6))", outputDirectory: outDir)
        request.cloneApp = true
        let manifest = try InstanceCreator.create(request, builderOptions: options).manifest
        let domain = try XCTUnwrap(manifest.clone?.bundleIdentifier)
        _ = try Shell.run("/usr/bin/defaults", ["write", domain, "lastVault", "Work"])
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(domain).plist")
        defer { Shell.runAllowingFailure("/usr/bin/defaults", ["delete", domain]); try? FileManager.default.removeItem(at: file) }

        let destination = tempDir.appendingPathComponent("instance-copy", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        InstanceRemover.moveSystemState(of: manifest, into: destination)

        let saved = try XCTUnwrap(NSDictionary(contentsOf: destination.appendingPathComponent("preferences.plist")))
        XCTAssertEqual(saved["lastVault"] as? String, "Work", "preferences travel with the instance's data")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing left in ~/Library/Preferences")
    }

    func testServicesAndHelpersInsideTheCopyGetTheRedirectToo() throws {
        let target = try Fixtures.makeHomeReportingApp(named: "Servy", bundleID: "com.fake.servy", in: tempDir)
        // An XPC service, as macOS launches it (not inheriting the launcher's environment).
        let service = target.appendingPathComponent("Contents/XPCServices/Worker.xpc/Contents")
        try FileManager.default.createDirectory(at: service.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: service.appendingPathComponent("MacOS/Worker").path)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.fake.servy.worker", "CFBundleExecutable": "Worker", "CFBundlePackageType": "XPC!",
            "XPCService": ["ServiceType": "Application"],
        ] as [String: Any], format: .xml, options: 0).write(to: service.appendingPathComponent("Info.plist"))

        var request = CreateRequest(appReference: target.path, name: "Servy Work", outputDirectory: outDir)
        request.cloneApp = true
        let result = try InstanceCreator.create(request, builderOptions: options)

        let plist = try XCTUnwrap(NSDictionary(contentsOf: result.wrapperURL
            .appendingPathComponent("Contents/XPCServices/Worker.xpc/Contents/Info.plist")) as? [String: Any])
        let variables = try XCTUnwrap((plist["XPCService"] as? [String: Any])?["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(variables["PARALLEX_HOME_REDIRECT"], result.manifest.redirectedHome)
        XCTAssertEqual(variables["PARALLEX_HOME_SCOPE"], result.wrapperURL.standardizedFileURL.path)
        XCTAssertEqual(variables["DYLD_INSERT_LIBRARIES"], Paths.homeLibrary.path)
        XCTAssertEqual((plist["XPCService"] as? [String: Any])?["ServiceType"] as? String, "Application", "the rest is kept")
        // Still a validly signed copy.
        XCTAssertNoThrow(try Shell.run("/usr/bin/codesign", ["--verify", "--deep", result.wrapperURL.path]))
    }

    func testAMovedCopyRefusesToRunUnredirected() throws {
        let target = try Fixtures.makeHomeReportingApp(named: "Movy", bundleID: "com.fake.movy", in: tempDir)
        var request = CreateRequest(appReference: target.path, name: "Movy Work", outputDirectory: outDir)
        request.cloneApp = true
        let result = try InstanceCreator.create(request, builderOptions: options)
        let moved = tempDir.appendingPathComponent("Elsewhere.app")
        try FileManager.default.moveItem(at: result.wrapperURL, to: moved)

        let out = tempDir.appendingPathComponent("moved.txt")
        let process = Process()
        process.executableURL = moved.appendingPathComponent("Contents/MacOS/parallex-launcher")
        var environment = ProcessInfo.processInfo.environment
        environment["FIXTURE_OUT"] = out.path
        environment["PARALLEX_LAUNCHER_NO_UI"] = "1"
        process.environment = environment
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "the app never ran with the real Library")
    }

    /// If macOS stops loading the library into copies, the launcher notices
    /// before the app runs (it would have used the real Library), leaves a
    /// note the app explains, and clears it once separation works again.
    func testACopyMacOSWontSeparateDoesntOpen() throws {
        let target = try Fixtures.makeHomeReportingApp(named: "Stricty", bundleID: "com.fake.stricty", in: tempDir)
        var request = CreateRequest(appReference: target.path, name: "Stricty Work", outputDirectory: outDir)
        request.cloneApp = true
        let result = try InstanceCreator.create(request, builderOptions: options)
        let launcher = result.wrapperURL.appendingPathComponent("Contents/MacOS/parallex-launcher")
        let marker = Paths.instanceDir(slug: "stricty-work").appendingPathComponent(ParallexConfig.separationUnavailableMarker)

        func launch() throws -> (status: Int32, ran: Bool) {
            let out = tempDir.appendingPathComponent("report-\(UUID().uuidString).txt")
            let process = Process()
            process.executableURL = launcher
            var environment = ProcessInfo.processInfo.environment
            environment["FIXTURE_OUT"] = out.path
            environment["PARALLEX_LAUNCHER_NO_UI"] = "1"
            process.environment = environment
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            for _ in 0..<40 where !FileManager.default.fileExists(atPath: out.path) {
                Thread.sleep(forTimeInterval: 0.05)
            }
            return (process.terminationStatus, FileManager.default.fileExists(atPath: out.path))
        }

        // The hardened runtime makes dyld ignore inserted libraries: what a
        // stricter macOS would do to every copy. (Not with System Integrity
        // Protection off, as on CI machines: then dyld loads them anyway.)
        let sip = (try? Shell.run("/usr/bin/csrutil", ["status"])) ?? ""
        try XCTSkipUnless(sip.contains("enabled"), "needs System Integrity Protection on to simulate a stricter macOS")
        try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", "--options", "runtime", launcher.path])
        let refused = try launch()
        XCTAssertNotEqual(refused.status, 0)
        XCTAssertFalse(refused.ran, "the app never ran with the real Library")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(InstanceStatus.check(result.manifest).problems.contains(.separationUnavailable))

        try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", launcher.path])
        let opened = try launch()
        XCTAssertEqual(opened.status, 0)
        XCTAssertTrue(opened.ran)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the note goes once separation works")
        XCTAssertFalse(InstanceStatus.check(result.manifest).problems.contains(.separationUnavailable))
    }

    /// Apps built on Node (Electron) find "~" through $HOME. A copy sees its
    /// instance's home there, as it does through the account lookup, and that
    /// home mirrors yours: the app's own hidden folder is private, everything
    /// else is your real one. Both kinds of copy home are covered: home mode
    /// (native apps) and a dedicated home (apps run with framework flags).
    func testNodeBasedCopySeesAMirroredHome() throws {
        let node = try XCTUnwrap(
            ((try? Shell.run("/usr/bin/which", ["node"])) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            "needs node on PATH"
        )
        // A copied binary has to run on its own (Homebrew's node loads
        // libnode from next to itself; standalone builds don't).
        let nodeBinary = URL(fileURLWithPath: node).resolvingSymlinksInPath().path
        let linked = (try? Shell.run("/usr/bin/otool", ["-L", nodeBinary])) ?? ""
        try XCTSkipIf(linked.contains("@rpath/"), "needs a standalone node build")
        let app = tempDir.appendingPathComponent("Nodey.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Shell.run("/bin/cp", [URL(fileURLWithPath: node).resolvingSymlinksInPath().path, macOS.appendingPathComponent("Nodey").path])
        let plist: [String: Any] = [
            "CFBundleExecutable": "Nodey", "CFBundleIdentifier": "com.fake.nodey", "CFBundleName": "Nodey",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let script = tempDir.appendingPathComponent("probe.js")
        try """
            const fs = require('fs'), os = require('os'), path = require('path'), cp = require('child_process');
            const home = os.homedir();
            fs.mkdirSync(path.join(home, '.nodey'), { recursive: true });
            fs.writeFileSync(path.join(home, '.nodey', 'state'), 'mine');
            const child = cp.execFileSync('/bin/sh', ['-c', 'echo "$HOME"; ls -a "$HOME"']).toString().trim().split('\\n');
            fs.writeFileSync(process.env.FIXTURE_OUT, JSON.stringify({
                homedir: home, env: process.env.HOME, childHome: child[0], childEntries: child.slice(1),
                entries: fs.readdirSync(home),
            }));
            """.write(to: script, atomically: true, encoding: .utf8)
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        let realEntries = Set((try? FileManager.default.contentsOfDirectory(atPath: realHome)) ?? [])
            .subtracting(["Library", ".Trash", ".DS_Store", ".nodey"])

        for (name, mode) in [("Nodey Home", RequestedMode.auto), ("Nodey Plain", .launchOnly)] {
            var request = CreateRequest(appReference: app.path, name: name, mode: mode, outputDirectory: outDir)
            request.cloneApp = true
            request.extraArguments = [script.path]
            let result = try InstanceCreator.create(request, builderOptions: options)
            let home = try XCTUnwrap(result.manifest.redirectedHome, name)
            // Home mode (native apps' default) keeps a home of its own; a
            // dedicated home (apps run with framework flags) mirrors yours.
            let mirrored = result.manifest.mode != .home

            let out = tempDir.appendingPathComponent("\(name).json")
            let process = Process()
            process.executableURL = result.wrapperURL.appendingPathComponent("Contents/MacOS/parallex-launcher")
            var environment = ProcessInfo.processInfo.environment
            environment["FIXTURE_OUT"] = out.path
            environment["PARALLEX_LAUNCHER_NO_UI"] = "1"
            process.environment = environment
            try process.run()
            process.waitUntilExit()
            let report = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any], "\(name) ran"
            )
            XCTAssertEqual(report["homedir"] as? String, home, "\(name): os.homedir() is the instance's home")
            XCTAssertEqual(report["env"] as? String, home, name)
            XCTAssertEqual(try String(contentsOfFile: home + "/.nodey/state", encoding: .utf8), "mine")
            XCTAssertFalse(FileManager.default.fileExists(atPath: realHome + "/.nodey"), "nothing in your real home")
            let entries = Set(report["entries"] as? [String] ?? [])
            if realEntries.contains("Documents") {
                XCTAssertEqual(try? FileManager.default.destinationOfSymbolicLink(atPath: home + "/Documents"), realHome + "/Documents")
            }
            if mirrored {
                XCTAssertTrue(result.manifest.privateHomeItems?.contains(".nodey") == true, name)
                // Everything else in your home is there, as the real thing…
                XCTAssertTrue(realEntries.isSubset(of: entries), "\(name) missing: \(realEntries.subtracting(entries).sorted())")
                // …and a tool the app starts gets your real home back.
                XCTAssertEqual(report["childHome"] as? String, realHome, name)
            } else {
                XCTAssertNil(result.manifest.privateHomeItems, name)
                XCTAssertFalse(realEntries.subtracting(Presets.defaultSharedItems).isSubset(of: entries),
                               "\(name): home mode doesn't mirror your home")
                XCTAssertEqual(report["childHome"] as? String, home, "\(name): home mode's $HOME is the instance's, on purpose")
            }
        }
    }

    /// A new copy keeps its own "<App> Safe Storage" key (what Electron and
    /// Chromium apps encrypt their data with) under a name of its own, so it
    /// neither prompts for nor shares the original's. Both keychain APIs are
    /// covered, other items are untouched. Runs against a throwaway keychain.
    func testACopyKeepsItsOwnSafeStorageKey() throws {
        let keychain = tempDir.appendingPathComponent("probe.keychain-db").path
        // Creating a keychain adds it to your search list; put the list back
        // right away (the probe names its keychain explicitly).
        let searchList = try Shell.run("/usr/bin/security", ["list-keychains", "-d", "user"])
        let savedList = searchList.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            .filter { !$0.isEmpty }
        try XCTSkipIf(savedList.isEmpty, "couldn't read the keychain search list")
        try Shell.run("/usr/bin/security", ["create-keychain", "-p", "probe", keychain])
        Shell.runAllowingFailure("/usr/bin/security", ["list-keychains", "-d", "user", "-s"] + savedList)
        defer { Shell.runAllowingFailure("/usr/bin/security", ["delete-keychain", keychain]) }
        try Shell.run("/usr/bin/security", ["unlock-keychain", "-p", "probe", keychain])

        let source = tempDir.appendingPathComponent("kc.c")
        try """
            #include <Security/Security.h>
            #include <stdio.h>
            #include <stdlib.h>
            #include <string.h>
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            int main(void) {
                SecKeychainRef kc = NULL;
                if (SecKeychainOpen(getenv("PROBE_KEYCHAIN"), &kc) != 0) return 2;
                OSStatus add1 = SecKeychainAddGenericPassword(kc, 18, "Probe Safe Storage", 5, "Probe", 3, "pw1", NULL);
                OSStatus add2 = SecKeychainAddGenericPassword(kc, 5, "Other", 5, "Probe", 3, "pw3", NULL);
                OSStatus add4 = SecKeychainAddGenericPassword(kc, 19, "Chrome Safe Storage", 6, "Chrome", 3, "pw4", NULL);
                CFArrayRef list = CFArrayCreate(NULL, (const void **)&kc, 1, &kCFTypeArrayCallBacks);
                const void *keys[] = { kSecClass, kSecAttrService, kSecAttrAccount, kSecValueData, kSecUseKeychain };
                CFDataRef pw2 = CFDataCreate(NULL, (const UInt8 *)"pw2", 3);
                const void *values[] = { kSecClassGenericPassword, CFSTR("Modern Safe Storage"), CFSTR("Modern"), pw2, kc };
                CFDictionaryRef item = CFDictionaryCreate(NULL, keys, values, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
                OSStatus add3 = SecItemAdd(item, NULL);
                UInt32 length = 0; void *data = NULL;
                OSStatus find = SecKeychainFindGenericPassword(list, 18, "Probe Safe Storage", 5, "Probe", &length, &data, NULL);
                int found = find == 0 && length == 3 && memcmp(data, "pw1", 3) == 0;
                const void *qkeys[] = { kSecClass, kSecAttrService, kSecMatchSearchList, kSecReturnData };
                const void *qvalues[] = { kSecClassGenericPassword, CFSTR("Modern Safe Storage"), list, kCFBooleanTrue };
                CFDictionaryRef query = CFDictionaryCreate(NULL, qkeys, qvalues, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
                CFTypeRef result = NULL;
                OSStatus copy = SecItemCopyMatching(query, &result);
                int copied = copy == 0 && result != NULL && CFDataGetLength(result) == 3;
                FILE *out = fopen(getenv("FIXTURE_OUT"), "w");
                fprintf(out, "%d %d %d %d %d %d", (int)add1, (int)add2, (int)add3, found, copied, (int)add4);
                fclose(out);
                return 0;
            }
            """.write(to: source, atomically: true, encoding: .utf8)
        let app = tempDir.appendingPathComponent("Keyed.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Shell.run("/usr/bin/clang", [source.path, "-framework", "Security", "-framework", "CoreFoundation",
                                        "-o", macOS.appendingPathComponent("Keyed").path])
        let plist: [String: Any] = [
            "CFBundleExecutable": "Keyed", "CFBundleIdentifier": "com.fake.keyed", "CFBundleName": "Keyed",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))

        var request = CreateRequest(appReference: app.path, name: "Keyed Work", outputDirectory: outDir)
        request.cloneApp = true
        let result = try InstanceCreator.create(request, builderOptions: options)
        XCTAssertEqual(result.manifest.keychainSuffix, " (Parallex keyed-work)")

        let out = tempDir.appendingPathComponent("keyed.txt")
        let process = Process()
        process.executableURL = result.wrapperURL.appendingPathComponent("Contents/MacOS/parallex-launcher")
        var environment = ProcessInfo.processInfo.environment
        environment["FIXTURE_OUT"] = out.path
        environment["PROBE_KEYCHAIN"] = keychain
        environment["PARALLEX_LAUNCHER_NO_UI"] = "1"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "0 0 0 1 1 0", "adds and finds work, under the copy's names")

        func exists(_ service: String) -> Bool {
            (try? Shell.run("/usr/bin/security", ["find-generic-password", "-s", service, keychain])) != nil
        }
        XCTAssertTrue(exists("Probe Safe Storage (Parallex keyed-work)"))
        XCTAssertTrue(exists("Modern Safe Storage (Parallex keyed-work)"))
        XCTAssertFalse(exists("Probe Safe Storage"), "the original's name stays free")
        XCTAssertFalse(exists("Modern Safe Storage"))
        XCTAssertTrue(exists("Other"), "other items keep their names")
        XCTAssertTrue(exists("Chrome Safe Storage"), "another browser's key keeps its name (for importing from it)")
        XCTAssertFalse(exists("Chrome Safe Storage (Parallex keyed-work)"))

        // Its key name stays with it through a Library off-and-on.
        var off = result.manifest.effectiveSettings
        off.separateLibrary = false
        let without = try InstanceCreator.update(result.manifest, InstanceUpdate(settings: off), builderOptions: options).manifest
        XCTAssertEqual(without.keychainSuffix, " (Parallex keyed-work)")
        XCTAssertNil(plistConfig(without)[ParallexConfig.Key.keychainSuffix], "not used while the Library is shared")
        var on = without.effectiveSettings
        on.separateLibrary = true
        let again = try InstanceCreator.update(without, InstanceUpdate(settings: on), builderOptions: options).manifest
        XCTAssertEqual(plistConfig(again)[ParallexConfig.Key.keychainSuffix] as? String, " (Parallex keyed-work)")

        // A duplicate with data reads what it copied with its source's key;
        // a fresh one gets its own.
        let twin = try InstanceCreator.duplicate(again, includeData: true, builderOptions: options).manifest
        XCTAssertEqual(twin.keychainSuffix, " (Parallex keyed-work)")
        let fresh = try InstanceCreator.duplicate(again, builderOptions: options).manifest
        XCTAssertEqual(fresh.keychainSuffix, " (Parallex \(fresh.slug))")
    }

    func testToolsStartedByTheCopyDontInheritTheLibrary() throws {
        // A process outside the copy's bundle that inherits the variables
        // takes them out of its environment, so its children are clean.
        let out = tempDir.appendingPathComponent("env.txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // /usr/bin/env is protected (dyld ignores the insert), so run a
        // copy of it from outside the scope instead.
        let tool = tempDir.appendingPathComponent("tool")
        try FileManager.default.copyItem(atPath: "/usr/bin/env", toPath: tool.path)
        _ = try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", tool.path])
        process.executableURL = tool
        process.arguments = ["/usr/bin/env"]
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_INSERT_LIBRARIES"] = Fixtures.homeLibrary.path
        environment["PARALLEX_HOME_REDIRECT"] = tempDir.path
        environment["PARALLEX_HOME_SCOPE"] = "/Applications/Somewhere Else.app"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let printed = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertFalse(printed.contains("PARALLEX_HOME_REDIRECT"), printed)
        XCTAssertFalse(printed.contains("libparallexhome"), printed)
        _ = out
    }

    func testRemovingACopyLeavesNoPreferencesBehind() throws {
        let target = try Fixtures.makeHomeReportingApp(named: "Gone", bundleID: "com.fake.gone", in: tempDir)
        var request = CreateRequest(appReference: target.path, name: "Gone Test \(UUID().uuidString.prefix(6))", outputDirectory: outDir)
        request.cloneApp = true
        let manifest = try InstanceCreator.create(request, builderOptions: options).manifest
        let domain = try XCTUnwrap(manifest.clone?.bundleIdentifier)
        _ = try Shell.run("/usr/bin/defaults", ["write", domain, "k", "v"])
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(domain).plist")
        defer { Shell.runAllowingFailure("/usr/bin/defaults", ["delete", domain]); try? FileManager.default.removeItem(at: file) }

        _ = try InstanceRemover.remove(manifest, keepData: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testStartingFromTheOriginalsData() throws {
        let target = try Fixtures.makeHomeReportingApp(named: "Seedy", bundleID: "com.fake.seedy", in: tempDir)
        var request = CreateRequest(appReference: target.path, name: "Seedy Work", outputDirectory: outDir)
        request.cloneApp = true
        let manifest = try InstanceCreator.create(request, builderOptions: options).manifest
        let home = try XCTUnwrap(manifest.redirectedHome)

        // A stand-in for the real home with the original's data.
        let realHome = tempDir.appendingPathComponent("realhome", isDirectory: true)
        let support = realHome.appendingPathComponent("Library/Application Support/Seedy")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("account=me".utf8).write(to: support.appendingPathComponent("session"))
        try FileManager.default.createSymbolicLink(atPath: support.appendingPathComponent("SingletonLock").path, withDestinationPath: "x-1")
        let cookies = realHome.appendingPathComponent("Library/HTTPStorages/com.fake.seedy")
        try FileManager.default.createDirectory(at: cookies, withIntermediateDirectories: true)
        try Data("cookie".utf8).write(to: cookies.appendingPathComponent("httpstorages.sqlite"))
        let config = realHome.appendingPathComponent(".config/seedy")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)

        let planned = OriginalData.plan(for: manifest, realHome: realHome).map(\.label)
        XCTAssertEqual(Set(planned), ["Application Support/Seedy", "web storage", "~/.config/seedy"])

        // Something the instance already had is replaced.
        let existing = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Seedy")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: existing.appendingPathComponent("session"))

        XCTAssertEqual(manifest.keychainSuffix, " (Parallex seedy-work)", "a new copy has its own key")
        try OriginalData.copy(into: manifest, realHome: realHome, builderOptions: options)
        XCTAssertEqual(try String(contentsOf: existing.appendingPathComponent("session"), encoding: .utf8), "account=me")
        // The original's data needs the original's key.
        let after = try XCTUnwrap(InstanceStore.load(slug: "seedy-work"))
        XCTAssertNil(after.keychainSuffix)
        XCTAssertNil(plistConfig(after)[ParallexConfig.Key.keychainSuffix])
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: existing.appendingPathComponent("SingletonLock").path))
        let copiedCookies = URL(fileURLWithPath: home).appendingPathComponent("Library/HTTPStorages/\(manifest.clone!.bundleIdentifier)/httpstorages.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedCookies.path), "keyed by the copy's own bundle ID")
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent("session").path), "the original is untouched")
    }

    func testCopyingNeverWritesThroughLinksToTheRealHome() throws {
        let target = try Fixtures.makeHomeReportingApp(named: "Linky", bundleID: "com.fake.linky", in: tempDir)
        var request = CreateRequest(appReference: target.path, name: "Linky Work", outputDirectory: outDir)
        request.cloneApp = true
        request.extraSharedItems = [".config"]
        let manifest = try InstanceCreator.create(request, builderOptions: options).manifest
        let home = URL(fileURLWithPath: try XCTUnwrap(manifest.redirectedHome))

        let realHome = tempDir.appendingPathComponent("realhome", isDirectory: true)
        for folder in [".config/linky", "Library/Application Support/Linky", "Library/Application Support/Planted"] {
            try FileManager.default.createDirectory(at: realHome.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        // The instance home shares .config (a link to the real one) …
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".config"),
                                                   withDestinationURL: realHome.appendingPathComponent(".config"))
        // … and something planted a link where app data would go.
        let support = home.appendingPathComponent("Library/Application Support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("Linky"),
                                                   withDestinationURL: realHome.appendingPathComponent("Library/Application Support/Linky"))

        let labels = OriginalData.plan(for: manifest, realHome: realHome).map(\.label)
        XCTAssertFalse(labels.contains("~/.config/linky"), "shared folders are left alone")
        XCTAssertFalse(labels.contains("Application Support/Linky"), "never through a link")
        XCTAssertTrue(FileManager.default.fileExists(atPath: realHome.appendingPathComponent(".config/linky").path))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
