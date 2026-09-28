import XCTest
@testable import ParallexCore
import ParallexKit

/// Copies are signed with this Mac's own identity, so what macOS allows
/// them (privacy permissions, keychain items) is tied to their bundle ID
/// and that certificate instead of their exact code, and survives refreshes.
final class SigningIdentityTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("signing")
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
        unsetenv("PARALLEX_SIGNING")
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func requirement(_ app: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "-r-", app.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return try XCTUnwrap(output.split(separator: "\n").first { $0.contains("designated =>") }.map(String.init))
    }

    private func searchList() throws -> String {
        try Shell.run("/usr/bin/security", ["list-keychains", "-d", "user"])
    }

    func testCopiesKeepTheirRequirementAcrossRefreshes() throws {
        let target = try Fixtures.makeApp(
            named: "Steady", bundleID: "com.fake.steady", in: tempDir,
            extraInfoKeys: ["CFBundleShortVersionString": "1.0"]
        )
        var request = CreateRequest(appReference: target.path, name: "Steady Work", outputDirectory: outDir)
        request.cloneApp = true
        let result = try InstanceCreator.create(request, builderOptions: options)
        let identity = try XCTUnwrap(SigningIdentity.existing())

        let first = try requirement(result.wrapperURL)
        XCTAssertTrue(first.contains("identifier \"com.parallex.instance.steady-work\""), first)
        XCTAssertTrue(first.contains("certificate leaf = H\"\(identity.hash.lowercased())\""), first)
        XCTAssertNoThrow(try Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", result.wrapperURL.path]))

        // The app updates; the refreshed copy has new code but the same
        // requirement, so macOS still recognizes it.
        let plistURL = target.appendingPathComponent("Contents/Info.plist")
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        plist["CFBundleShortVersionString"] = "2.0"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
        let refreshed = try InstanceCreator.update(result.manifest, builderOptions: options)
        XCTAssertEqual(try requirement(refreshed.wrapperURL), first)
    }

    func testTheIdentityIsMadeOnceAndKeptOffTheKeychainSearchList() throws {
        let before = try searchList()
        let identity = try XCTUnwrap(SigningIdentity.forSigning())
        XCTAssertEqual(SigningIdentity.forSigning(), identity, "made once, then reused")
        XCTAssertEqual(try searchList(), before, "never added to your keychain search list")
        XCTAssertFalse(before.contains("Parallex Signing"))

        let attributes = try FileManager.default.attributesOfItem(atPath: SigningIdentity.passwordURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "its password is yours alone")
        let identities = try Shell.run("/usr/bin/security", ["find-identity", "-p", "codesigning", identity.keychain.path])
        XCTAssertTrue(identities.contains(identity.hash), identities)
    }

    func testTurnedOffCopiesAreSignedAdHoc() throws {
        setenv("PARALLEX_SIGNING", "adhoc", 1)
        let target = try Fixtures.makeApp(named: "Loose", bundleID: "com.fake.loose", in: tempDir)
        var request = CreateRequest(appReference: target.path, name: "Loose Work", outputDirectory: outDir)
        request.cloneApp = true
        let result = try InstanceCreator.create(request, builderOptions: options)
        XCTAssertTrue(try requirement(result.wrapperURL).contains("cdhash H\""))
    }
}
