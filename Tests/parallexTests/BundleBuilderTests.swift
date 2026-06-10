import XCTest
@testable import ParallexCore
import ParallexKit

final class BundleBuilderTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    var launcherStub: URL!

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("builder")
        outDir = tempDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        // A real, signable Mach-O standing in for the launcher.
        launcherStub = tempDir.appendingPathComponent("launcher-stub")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: launcherStub)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeSpec(name: String = "Fake Work") -> WrapperSpec {
        WrapperSpec(
            name: name,
            slug: "fake-work",
            bundleIdentifier: "com.parallex.instance.fake-work",
            targetAppPath: "/Applications/Fake.app",
            targetBinaryPath: "/Applications/Fake.app/Contents/MacOS/Fake",
            arguments: ["--user-data-dir=/tmp/fake-data"],
            environment: ["PARALLEX_INSTANCE": "fake-work"],
            homeOverride: nil,
            homeSymlinks: [],
            createDirectories: ["/tmp/fake-data"],
            applicationCategory: "public.app-category.productivity",
            outputDirectory: outDir,
            launcherBinary: launcherStub,
            iconSource: nil,
            badge: nil
        )
    }

    private func makeBuilder() -> BundleBuilder {
        BundleBuilder(options: .init(registerWithLaunchServices: false))
    }

    private func readInfoPlist(_ wrapper: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: wrapper.appendingPathComponent("Contents/Info.plist"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testBuildProducesSignedWrapper() throws {
        let builder = makeBuilder()
        let output = try builder.build(makeSpec())
        let wrapper = output.url

        XCTAssertTrue(output.warnings.isEmpty)
        XCTAssertEqual(wrapper.lastPathComponent, "Fake Work.app")
        let fm = FileManager.default
        let launcher = wrapper.appendingPathComponent("Contents/MacOS/launcher")
        XCTAssertTrue(fm.isExecutableFile(atPath: launcher.path))

        let info = try readInfoPlist(wrapper)
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.parallex.instance.fake-work")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "launcher")
        XCTAssertEqual(info["LSApplicationCategoryType"] as? String, "public.app-category.productivity")
        XCTAssertNil(info["CFBundleIconFile"], "no icon source was given")

        let config = try XCTUnwrap(info[ParallexConfig.rootKey] as? [String: Any])
        XCTAssertEqual(config[ParallexConfig.Key.targetBinary] as? String, "/Applications/Fake.app/Contents/MacOS/Fake")
        XCTAssertEqual(config[ParallexConfig.Key.arguments] as? [String], ["--user-data-dir=/tmp/fake-data"])
        XCTAssertEqual(config[ParallexConfig.Key.environment] as? [String: String], ["PARALLEX_INSTANCE": "fake-work"])
        XCTAssertEqual(config[ParallexConfig.Key.createDirectories] as? [String], ["/tmp/fake-data"])
        XCTAssertEqual(config[ParallexConfig.Key.slug] as? String, "fake-work")
        XCTAssertNil(config[ParallexConfig.Key.homeOverride])

        // Ad-hoc signature must verify.
        XCTAssertNoThrow(try Shell.run("/usr/bin/codesign", ["--verify", wrapper.path]))
    }

    func testHomeOverrideKeysAreWritten() throws {
        var spec = makeSpec(name: "Fake Home")
        spec.slug = "fake-home"
        spec.arguments = []
        spec.createDirectories = []
        spec.homeOverride = "/tmp/fake-home"
        spec.homeSymlinks = ["Downloads", ".gitconfig"]
        let builder = makeBuilder()
        let wrapper = try builder.build(spec).url

        let info = try readInfoPlist(wrapper)
        let config = try XCTUnwrap(info[ParallexConfig.rootKey] as? [String: Any])
        XCTAssertEqual(config[ParallexConfig.Key.homeOverride] as? String, "/tmp/fake-home")
        XCTAssertEqual(config[ParallexConfig.Key.homeSymlinks] as? [String], ["Downloads", ".gitconfig"])
        XCTAssertNil(config[ParallexConfig.Key.arguments])
    }

    func testRefusesToReplaceForeignBundle() throws {
        // An .app at the destination that Parallex did not create.
        try Fixtures.makeApp(named: "Fake Work", bundleID: "com.fake.foreign", in: outDir)
        let builder = makeBuilder()
        XCTAssertThrowsError(try builder.build(makeSpec())) { error in
            XCTAssertTrue("\(error)".contains("not a Parallex wrapper"))
        }
    }

    func testReplacesOwnWrapper() throws {
        let builder = makeBuilder()
        let first = try builder.build(makeSpec()).url
        XCTAssertTrue(BundleBuilder.isParallexWrapper(first))
        // Building again over our own wrapper succeeds (old copy → Trash).
        let second = try builder.build(makeSpec()).url
        XCTAssertEqual(first.path, second.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testPidFileKeyIsWritten() throws {
        var spec = makeSpec(name: "Fake Pid")
        spec.slug = "fake-pid"
        spec.pidFile = "/tmp/fake-pid/instance.pid"
        let wrapper = try makeBuilder().build(spec).url
        let info = try readInfoPlist(wrapper)
        let config = try XCTUnwrap(info[ParallexConfig.rootKey] as? [String: Any])
        XCTAssertEqual(config[ParallexConfig.Key.pidFile] as? String, "/tmp/fake-pid/instance.pid")
    }
}
