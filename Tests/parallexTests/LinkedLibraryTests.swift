import XCTest
@testable import ParallexCore
import ParallexKit

/// A copy's code loads the home-redirect library by itself (a load command
/// Parallex adds), so it keeps its own Library even without
/// DYLD_INSERT_LIBRARIES, which a future macOS might stop honoring.
final class LinkedLibraryTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)
    /// Linkers leave almost no room after the load commands by default;
    /// real apps' binaries (and Electron's framework) have plenty.
    let roomy = ["-Wl,-headerpad,0x400"]

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("linked")
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

    private func compile(_ name: String, flags: [String]) throws -> URL {
        let source = tempDir.appendingPathComponent("\(name).c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        let binary = tempDir.appendingPathComponent(name)
        try Shell.run("/usr/bin/clang", [source.path, "-o", binary.path] + flags)
        return binary
    }

    private func loads(_ binary: URL) throws -> String {
        try Shell.run("/usr/bin/otool", ["-l", binary.path])
    }

    func testTheLinkerAddsAWeakLoadCommandWhereThereIsRoom() throws {
        let binary = try compile("roomy", flags: roomy)
        let linked = try MachOLinker.addWeakLibrary("/tmp/libexample.dylib", to: binary)
        XCTAssertFalse(linked.isEmpty)
        let commands = try loads(binary)
        XCTAssertTrue(commands.contains("LC_LOAD_WEAK_DYLIB"), commands)
        XCTAssertTrue(commands.contains("/tmp/libexample.dylib"))
        XCTAssertEqual(try MachOLinker.addWeakLibrary("/tmp/libexample.dylib", to: binary), linked, "added once")
        try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", binary.path])
        XCTAssertNoThrow(try Shell.run(binary.path, []), "runs, even though that library doesn't exist (weak)")

        let tight = try compile("tight", flags: [])
        let before = try Data(contentsOf: tight)
        XCTAssertTrue(try MachOLinker.addWeakLibrary("/tmp/libexample.dylib", to: tight).isEmpty)
        XCTAssertEqual(try Data(contentsOf: tight), before, "no room: left exactly as it was")
    }

    func testTheLinkerLeavesWhatIsntAMachOAlone() throws {
        let junk = tempDir.appendingPathComponent("junk")
        var bytes = [UInt8](repeating: 0xAB, count: 512)
        bytes.replaceSubrange(0..<4, with: [0xCF, 0xFA, 0xED, 0xFE]) // a Mach-O's magic, then nonsense
        try Data(bytes).write(to: junk)
        XCTAssertTrue(try MachOLinker.addWeakLibrary("/tmp/libexample.dylib", to: junk).isEmpty)
        let fat = tempDir.appendingPathComponent("fat")
        try Data([0xCA, 0xFE, 0xBA, 0xBE, 0xFF, 0xFF, 0xFF, 0xFF] + [UInt8](repeating: 0, count: 64)).write(to: fat)
        XCTAssertTrue(try MachOLinker.addWeakLibrary("/tmp/libexample.dylib", to: fat).isEmpty)
    }

    func testACopyLoadsItsLibraryWithoutDYLDInsertLibraries() throws {
        let target = try Fixtures.makeHomeReportingApp(named: "Linky", bundleID: "com.fake.linky", in: tempDir, linkerFlags: roomy)
        var request = CreateRequest(appReference: target.path, name: "Linky Work", outputDirectory: outDir)
        request.cloneApp = true
        let result = try InstanceCreator.create(request, builderOptions: options)
        let config = try XCTUnwrap(NSDictionary(contentsOf: result.wrapperURL.appendingPathComponent("Contents/Info.plist"))?[ParallexConfig.rootKey] as? [String: Any])
        XCTAssertEqual(config[ParallexConfig.Key.homeLibraryLinked] as? Bool, true)
        let binary = result.wrapperURL.appendingPathComponent("Contents/MacOS/Linky")
        XCTAssertTrue(try loads(binary).contains(Paths.homeLibrary.path), "names the library the launcher inserts")
        XCTAssertNoThrow(try Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", result.wrapperURL.path]))

        // Only the copy's settings, no DYLD_INSERT_LIBRARIES: it still sees its own home.
        let home = try XCTUnwrap(result.manifest.redirectedHome)
        let out = tempDir.appendingPathComponent("direct.txt")
        let process = Process()
        process.executableURL = binary
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_INSERT_LIBRARIES"] = nil
        environment["PARALLEX_HOME_REDIRECT"] = home
        environment["PARALLEX_HOME_SCOPE"] = result.wrapperURL.path
        environment["FIXTURE_OUT"] = out.path
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8).split(separator: "\n").first.map(String.init), home)

        // And through its launcher as usual (both ways at once: loaded once).
        let viaLauncher = tempDir.appendingPathComponent("launcher.txt")
        let launch = Process()
        launch.executableURL = result.wrapperURL.appendingPathComponent("Contents/MacOS/parallex-launcher")
        environment = ProcessInfo.processInfo.environment
        environment["FIXTURE_OUT"] = viaLauncher.path
        launch.environment = environment
        try launch.run()
        launch.waitUntilExit()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: viaLauncher.path) { usleep(50_000) }
        XCTAssertEqual(try String(contentsOf: viaLauncher, encoding: .utf8).split(separator: "\n").first.map(String.init), home)
    }

    /// Electron apps: their framework is loaded by the app and every helper.
    func testAnElectronCopyLinksItsFramework() throws {
        let target = try Fixtures.makeApp(named: "Elec", bundleID: "com.fake.elec", in: tempDir, electron: true)
        let fm = FileManager.default
        let framework = target.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        let versionA = framework.appendingPathComponent("Versions/A")
        try fm.createDirectory(at: versionA.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        let source = tempDir.appendingPathComponent("framework.c")
        try Data("int electron(void) { return 0; }\n".utf8).write(to: source)
        try Shell.run("/usr/bin/clang", ["-dynamiclib", source.path, "-o", versionA.appendingPathComponent("Electron Framework").path] + roomy)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.github.Electron.framework", "CFBundleExecutable": "Electron Framework",
            "CFBundlePackageType": "FMWK",
        ], format: .xml, options: 0).write(to: versionA.appendingPathComponent("Resources/Info.plist"))
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Electron Framework").path,
                                  withDestinationPath: "Versions/Current/Electron Framework")
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Resources").path, withDestinationPath: "Versions/Current/Resources")
        let main = target.appendingPathComponent("Contents/MacOS/Elec")
        try fm.removeItem(at: main)
        try fm.copyItem(at: try compile("elec-main", flags: []), to: main)

        var request = CreateRequest(appReference: target.path, name: "Elec Work", outputDirectory: outDir)
        request.cloneApp = true
        request.separateLibrary = true
        let result = try InstanceCreator.create(request, builderOptions: options)
        let copied = result.wrapperURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework")
        XCTAssertTrue(try loads(copied).contains(Paths.homeLibrary.path))
        XCTAssertFalse(try loads(target.appendingPathComponent("Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework"))
            .contains("libparallexhome"), "the original is untouched")
        let config = try XCTUnwrap(NSDictionary(contentsOf: result.wrapperURL.appendingPathComponent("Contents/Info.plist"))?[ParallexConfig.rootKey] as? [String: Any])
        XCTAssertEqual(config[ParallexConfig.Key.homeLibraryLinked] as? Bool, true)
        XCTAssertNoThrow(try Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", result.wrapperURL.path]))
    }
}
