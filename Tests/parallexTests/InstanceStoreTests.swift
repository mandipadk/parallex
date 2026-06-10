import XCTest
@testable import ParallexCore
import ParallexKit

final class InstanceStoreTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("store")
        setenv("PARALLEX_HOME", tempDir.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeManifest(name: String, slug: String) -> InstanceManifest {
        InstanceManifest(
            name: name,
            slug: slug,
            bundleIdentifier: "com.parallex.instance.\(slug)",
            targetApp: "/Applications/Fake.app",
            targetBinary: "/Applications/Fake.app/Contents/MacOS/Fake",
            wrapperPath: "/Applications/\(name).app",
            mode: .dataDir,
            preset: "electron",
            arguments: ["--user-data-dir=/tmp/x"],
            environment: ["PARALLEX_INSTANCE": slug],
            homeSymlinks: nil,
            createdAt: Date(),
            parallexVersion: ParallexConfig.version
        )
    }

    func testSaveLoadRoundTrip() throws {
        let original = makeManifest(name: "Fake Work", slug: "fake-work")
        try InstanceStore.save(original)

        let loaded = try XCTUnwrap(InstanceStore.load(slug: "fake-work"))
        XCTAssertEqual(loaded.name, original.name)
        XCTAssertEqual(loaded.bundleIdentifier, original.bundleIdentifier)
        XCTAssertEqual(loaded.mode, .dataDir)
        XCTAssertEqual(loaded.arguments, original.arguments)
        XCTAssertEqual(loaded.environment, original.environment)
        // ISO8601 storage keeps second precision.
        XCTAssertEqual(
            loaded.createdAt.timeIntervalSince1970,
            original.createdAt.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    func testLoadAllSortsByName() throws {
        try InstanceStore.save(makeManifest(name: "Zeta", slug: "zeta"))
        try InstanceStore.save(makeManifest(name: "alpha", slug: "alpha"))
        XCTAssertEqual(InstanceStore.loadAll().map(\.name), ["alpha", "Zeta"])
    }

    func testFindByNameSlugAndCase() throws {
        try InstanceStore.save(makeManifest(name: "Claude Work", slug: "claude-work"))
        XCTAssertNotNil(InstanceStore.find("claude-work"))
        XCTAssertNotNil(InstanceStore.find("Claude Work"))
        XCTAssertNotNil(InstanceStore.find("CLAUDE WORK"))
        XCTAssertNil(InstanceStore.find("nope"))
    }

    func testCorruptManifestIsSkipped() throws {
        try InstanceStore.save(makeManifest(name: "Good", slug: "good"))
        let badDir = Paths.instanceDir(slug: "bad")
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: badDir.appendingPathComponent(InstanceStore.manifestFilename))
        XCTAssertEqual(InstanceStore.loadAll().map(\.slug), ["good"])
    }
}
