import Security
import XCTest
@testable import ParallexCore
@testable import ParallexKit

/// A copy with its own Library keeps its sign-ins in a keychain of its own:
/// it never finds, or overwrites, the original's. The keychain's password
/// sits in a throwaway stand-in for the login keychain here (Fixtures).
final class InstanceKeychainTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)
    /// Unique per test, so nothing can collide with a real item.
    var service = ""

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("keychain")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
        setenv("PARALLEX_LAUNCHER", Fixtures.launcherBinary.path, 1)
        setenv("PARALLEX_HOME_LIBRARY", Fixtures.homeLibrary.path, 1)
        outDir = tempDir.appendingPathComponent("apps", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        service = "com.parallex.tests.token-\(UUID().uuidString)"
        // Never ask anything of whoever runs the tests: an item this
        // process may not read fails at once instead of prompting.
        SecKeychainSetUserInteractionAllowed(false)
    }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        unsetenv("PARALLEX_LAUNCHER")
        unsetenv("PARALLEX_HOME_LIBRARY")
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// An app that keeps a sign-in token the way current apps do (the data
    /// protection keychain, an access group), with a helper that reads it.
    private func makeTokenApp(named name: String) throws -> URL {
        let app = try Fixtures.makeApp(named: name, bundleID: "com.fake.\(name.lowercased())", in: tempDir)
        let source = tempDir.appendingPathComponent("\(name).c")
        try Data("""
        #include <CoreFoundation/CoreFoundation.h>
        #include <Security/Security.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        int main(void) {
            SecKeychainSetUserInteractionAllowed(false); // a prompt would be a failure here
            const char *mode = getenv("FIXTURE_MODE");
            CFStringRef service = CFStringCreateWithCString(NULL, getenv("FIXTURE_SERVICE"), kCFStringEncodingUTF8);
            CFMutableDictionaryRef q = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CFDictionarySetValue(q, kSecClass, kSecClassGenericPassword);
            CFDictionarySetValue(q, kSecAttrService, service);
            CFDictionarySetValue(q, kSecAttrAccount, CFSTR("me"));
            CFDictionarySetValue(q, kSecUseDataProtectionKeychain, kCFBooleanTrue);
            CFDictionarySetValue(q, kSecAttrAccessGroup, CFSTR("TEAMID.com.fake.shared"));
            OSStatus status;
            char value[64] = "";
            if (strcmp(mode, "add") == 0) {
                CFDictionarySetValue(q, kSecValueData, CFDataCreate(NULL, (const UInt8 *)"token-1", 7));
                status = SecItemAdd(q, NULL);
            } else {
                CFDictionarySetValue(q, kSecReturnData, kCFBooleanTrue);
                CFTypeRef data = NULL;
                status = SecItemCopyMatching(q, &data);
                if (status == 0) snprintf(value, sizeof value, "%.*s", (int)CFDataGetLength(data), CFDataGetBytePtr(data));
            }
            FILE *out = fopen(getenv("FIXTURE_OUT"), "w");
            fprintf(out, "%d %s", (int)status, value);
            fclose(out);
            return 0;
        }
        """.utf8).write(to: source)
        let executable = app.appendingPathComponent("Contents/MacOS/\(name)")
        try? FileManager.default.removeItem(at: executable)
        try Shell.run("/usr/bin/clang", ["-framework", "Security", "-framework", "CoreFoundation", source.path, "-o", executable.path])
        // The same program as a helper app inside it.
        let helper = app.appendingPathComponent("Contents/Frameworks/\(name) Helper.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: executable, to: helper.appendingPathComponent("\(name) Helper"))
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.fake.\(name.lowercased()).helper",
            "CFBundleExecutable": "\(name) Helper",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: helper.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        return app
    }

    private func makeCopy(of target: URL, name: String) throws -> CreateResult {
        var request = CreateRequest(appReference: target.path, name: name, outputDirectory: outDir)
        request.cloneApp = true
        return try InstanceCreator.create(request, builderOptions: options)
    }

    /// Open the copy through its launcher (the app runs as `add` or `read`).
    private func launch(_ copy: URL, _ mode: String) throws -> String {
        let out = tempDir.appendingPathComponent("out-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = copy.appendingPathComponent("Contents/MacOS/parallex-launcher")
        var environment = ProcessInfo.processInfo.environment
        environment["PARALLEX_LAUNCHER_NO_UI"] = "1"
        environment["FIXTURE_OUT"] = out.path
        environment["FIXTURE_MODE"] = mode
        environment["FIXTURE_SERVICE"] = service
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        return try String(contentsOf: out, encoding: .utf8)
    }

    /// Run one of the copy's helpers the way the app would start it: with
    /// the environment macOS gives it (its Info.plist's).
    private func runHelper(of copy: URL, named name: String) throws -> String {
        let helper = copy.appendingPathComponent("Contents/Frameworks/\(name) Helper.app")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: helper.appendingPathComponent("Contents/Info.plist")) as? [String: Any])
        let out = tempDir.appendingPathComponent("helper-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = helper.appendingPathComponent("Contents/MacOS/\(name) Helper")
        var environment = ProcessInfo.processInfo.environment
        environment.merge(plist["LSEnvironment"] as? [String: String] ?? [:]) { _, new in new }
        environment["FIXTURE_OUT"] = out.path
        environment["FIXTURE_MODE"] = "read"
        environment["FIXTURE_SERVICE"] = service
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        return try String(contentsOf: out, encoding: .utf8)
    }

    private func items(in keychain: String) throws -> String {
        (try? Shell.run("/usr/bin/security", ["find-generic-password", "-s", service, keychain])) ?? ""
    }

    func testACopyKeepsItsSignInsInItsOwnKeychain() throws {
        let target = try makeTokenApp(named: "Tokeny")
        let result = try makeCopy(of: target, name: "Tokeny Work")
        let keychain = Paths.instanceKeychain(slug: "tokeny-work").path
        XCTAssertEqual(result.manifest.instanceKeychain, keychain)

        XCTAssertEqual(try launch(result.wrapperURL, "add"), "0 ", "the data protection request works in the copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keychain), "the launcher made its keychain")
        XCTAssertTrue(try items(in: keychain).contains(service), "the token is in the copy's keychain")
        let password = InstanceKeychain.passwordFile(for: keychain)
        let permissions = try FileManager.default.attributesOfItem(atPath: password)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600, "its password is beside it, yours alone")
        // Not in the keychains everything else uses.
        XCTAssertNil(try? Shell.run("/usr/bin/security", ["find-generic-password", "-s", service]))

        XCTAssertEqual(try launch(result.wrapperURL, "read"), "0 token-1", "found again on the next launch")
        XCTAssertEqual(try runHelper(of: result.wrapperURL, named: "Tokeny"), "0 token-1",
                       "its helper reads it without asking, as with the app's access group")
    }

    func testTheOriginalNeverSeesTheCopysSignIns() throws {
        let target = try makeTokenApp(named: "Sepy")
        let result = try makeCopy(of: target, name: "Sepy Work")
        XCTAssertEqual(try launch(result.wrapperURL, "add"), "0 ")
        // The original, run as itself: no library, no copy keychain.
        let out = tempDir.appendingPathComponent("original")
        let process = Process()
        process.executableURL = target.appendingPathComponent("Contents/MacOS/Sepy")
        var environment = ProcessInfo.processInfo.environment
        environment["FIXTURE_OUT"] = out.path
        environment["FIXTURE_MODE"] = "read"
        environment["FIXTURE_SERVICE"] = service
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        XCTAssertFalse(try String(contentsOf: out, encoding: .utf8).hasPrefix("0 "), "the original doesn't find it")
    }

    /// The app updates and its copy is refreshed (new code, same signing
    /// identity): the copy still opens its keychain and finds its sign-in.
    func testTheCopyKeepsItsSignInsAcrossARefresh() throws {
        let target = try makeTokenApp(named: "Steady")
        let result = try makeCopy(of: target, name: "Steady Work")
        XCTAssertEqual(try launch(result.wrapperURL, "add"), "0 ")
        let refreshed = try InstanceCreator.update(result.manifest, builderOptions: options)
        XCTAssertEqual(try launch(refreshed.wrapperURL, "read"), "0 token-1")
        XCTAssertEqual(try runHelper(of: refreshed.wrapperURL, named: "Steady"), "0 token-1")
    }

    /// If its keychain can't be opened, the copy doesn't open: it would
    /// otherwise use your keychain and find the original's sign-ins.
    func testACopyWhoseKeychainWontOpenDoesntOpen() throws {
        let target = try makeTokenApp(named: "Locked")
        let result = try makeCopy(of: target, name: "Locked Work")
        XCTAssertEqual(try launch(result.wrapperURL, "add"), "0 ")
        let keychain = Paths.instanceKeychain(slug: "locked-work").path
        var opened: SecKeychain?
        XCTAssertEqual(SecKeychainOpen(keychain, &opened), errSecSuccess)
        SecKeychainLock(opened)
        try Data("not-its-password".utf8).write(to: URL(fileURLWithPath: InstanceKeychain.passwordFile(for: keychain)))

        let out = tempDir.appendingPathComponent("locked-out")
        let process = Process()
        process.executableURL = result.wrapperURL.appendingPathComponent("Contents/MacOS/parallex-launcher")
        var environment = ProcessInfo.processInfo.environment
        environment["FIXTURE_OUT"] = out.path
        environment["FIXTURE_MODE"] = "read"
        environment["FIXTURE_SERVICE"] = service
        process.environment = environment
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "the app never ran")
    }

    /// Copies that had their own Library before they had their own keychain
    /// keep sharing yours (their sign-ins are there) until it's turned on.
    func testOlderCopiesKeepYourKeychainUntilTurnedOn() throws {
        let target = try makeTokenApp(named: "Oldie")
        var old = try makeCopy(of: target, name: "Oldie Work").manifest
        old.instanceKeychain = nil
        old.safeStorageInKeychain = nil
        old.settings?.separateKeychain = nil
        old.parallexVersion = "1.0.0"
        XCTAssertEqual(old.effectiveSettings.separateKeychain, false)
        let rebuilt = try InstanceCreator.update(old, builderOptions: options)
        XCTAssertNil(rebuilt.manifest.instanceKeychain, "a routine rebuild doesn't sign it out")

        var settings = rebuilt.manifest.effectiveSettings
        settings.separateKeychain = true
        let turnedOn = try InstanceCreator.update(rebuilt.manifest, InstanceUpdate(settings: settings), builderOptions: options)
        XCTAssertEqual(turnedOn.manifest.instanceKeychain, Paths.instanceKeychain(slug: "oldie-work").path)
    }

    /// A keychain file without its password can't be opened by anyone:
    /// it's set aside and the copy gets a new one.
    func testAKeychainNobodyCanOpenIsReplaced() throws {
        let target = try makeTokenApp(named: "Orphan")
        let result = try makeCopy(of: target, name: "Orphan Work")
        let keychain = Paths.instanceKeychain(slug: "orphan-work").path
        try FileManager.default.createDirectory(atPath: (keychain as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var stray: SecKeychain?
        XCTAssertEqual("lost".withCString { SecKeychainCreate(keychain, 4, $0, false, nil, &stray) }, errSecSuccess)
        XCTAssertFalse(FileManager.default.fileExists(atPath: InstanceKeychain.passwordFile(for: keychain)))

        XCTAssertEqual(try launch(result.wrapperURL, "add"), "0 ")
        XCTAssertTrue(FileManager.default.fileExists(atPath: InstanceKeychain.passwordFile(for: keychain)))
        let folder = (keychain as NSString).deletingLastPathComponent
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder).contains { $0.hasPrefix("Instance.keychain-db.unusable-") })
    }

    /// A new copy's own encryption key ("<App> Safe Storage") is in its own
    /// keychain too, so it survives refreshes without asking.
    func testANewCopysSafeStorageKeyIsInItsOwnKeychain() throws {
        let target = try makeTokenApp(named: "Chromey")
        let result = try makeCopy(of: target, name: "Chromey Work")
        XCTAssertEqual(result.manifest.safeStorageInKeychain, true)
        service = "Chromey \(UUID().uuidString.prefix(6)) Safe Storage"
        XCTAssertEqual(try launch(result.wrapperURL, "add"), "0 ")
        let keychain = Paths.instanceKeychain(slug: "chromey-work").path
        XCTAssertTrue(try items(in: keychain).contains(service))
        XCTAssertNil(try? Shell.run("/usr/bin/security", ["find-generic-password", "-s", service]), "not in your keychains")
        XCTAssertNil(try? Shell.run("/usr/bin/security", ["find-generic-password", "-s", service + " (Parallex chromey-work)"]))
        let refreshed = try InstanceCreator.update(result.manifest, builderOptions: options)
        XCTAssertEqual(try launch(refreshed.wrapperURL, "read"), "0 token-1")
    }

    /// Signed any other way it couldn't open its keychain, so a copy that
    /// has one isn't rebuilt without this Mac's identity.
    func testACopyWithItsOwnKeychainIsntRebuiltWithoutTheIdentity() throws {
        let target = try makeTokenApp(named: "Keep")
        let result = try makeCopy(of: target, name: "Keep Work")
        setenv("PARALLEX_SIGNING", "adhoc", 1)
        defer { unsetenv("PARALLEX_SIGNING") }
        XCTAssertThrowsError(try InstanceCreator.update(result.manifest, builderOptions: options))
        XCTAssertEqual(InstanceStore.load(slug: "keep-work")?.instanceKeychain, result.manifest.instanceKeychain)
    }

    /// Its keychain not open (a helper macOS starts before the copy's
    /// launcher ran, say): its items are refused, never looked for in yours.
    func testWithoutItsKeychainOpenACopyGetsNothingFromYours() throws {
        let target = try makeTokenApp(named: "Shut")
        let result = try makeCopy(of: target, name: "Shut Work")
        XCTAssertEqual(try launch(result.wrapperURL, "add"), "0 ")
        var keychain: SecKeychain?
        XCTAssertEqual(SecKeychainOpen(Paths.instanceKeychain(slug: "shut-work").path, &keychain), errSecSuccess)
        SecKeychainLock(keychain)
        XCTAssertEqual(try runHelper(of: result.wrapperURL, named: "Shut"), "\(errSecNotAvailable) ")
    }

    /// Duplicated with its data, a copy whose key is renamed in your
    /// keychain shares that key, so the copied data can be read.
    func testADuplicateWithDataUsesTheKeyItsDataNeeds() throws {
        let target = try makeTokenApp(named: "Pair")
        var source = try makeCopy(of: target, name: "Pair Work").manifest
        source.safeStorageInKeychain = nil
        try InstanceStore.save(source)
        let twin = try InstanceCreator.duplicate(source, includeData: true, builderOptions: options)
        XCTAssertEqual(twin.manifest.keychainSuffix, source.keychainSuffix)
        XCTAssertNil(twin.manifest.safeStorageInKeychain)
        XCTAssertTrue(twin.warnings.isEmpty)

        // A source whose key is in its own keychain can't lend it: said so.
        let other = try makeCopy(of: target, name: "Pair Home").manifest
        XCTAssertEqual(other.safeStorageInKeychain, true)
        let second = try InstanceCreator.duplicate(other, includeData: true, builderOptions: options)
        XCTAssertTrue(second.warnings.contains { $0.contains("sign in there again") })
    }

    func testADuplicateStartsWithAKeychainOfItsOwn() throws {
        let target = try makeTokenApp(named: "Twin")
        let result = try makeCopy(of: target, name: "Twin Work")
        _ = try launch(result.wrapperURL, "add")
        let twin = try InstanceCreator.duplicate(result.manifest, includeData: true, builderOptions: options)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.instanceKeychain(slug: twin.manifest.slug).path),
                       "only the copy it belongs to can open a keychain, so it isn't copied")
        XCTAssertEqual(try launch(twin.wrapperURL, "read").prefix(2), "-2", "the duplicate starts signed out")
    }
}
