import XCTest
@testable import ParallexCore
import ParallexKit

/// App knowledge from the signed notices file adds to what Parallex was
/// built knowing, without a release.
final class KnowledgeTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("knowledge")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
    }

    override func tearDownWithError() throws {
        Knowledge.override = nil
        unsetenv("PARALLEX_HOME")
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testKnowledgeAddsDataFoldersHomeFoldersAndPorts() throws {
        let app = try Fixtures.makeApp(named: "Newish", bundleID: "com.fake.newish", in: tempDir)
        let info = try AppInspector.inspect(app)
        XCTAssertFalse(Guard.locations(for: info, privateHomeItems: nil, home: "/h").contains("/h/Library/Application Support/NewishCorp/"))

        Knowledge.override = [Advisories.AppKnowledge(
            bundleID: "com.fake.newish", versions: nil, dataFolders: ["NewishCorp", "../escape"],
            homeFolders: [".newish-cli", "not-hidden", ".config/newish"],
            singleInstancePorts: [.init(base: 41000, plusUserID: true), .init(base: 80, plusUserID: nil)]
        )]
        XCTAssertTrue(Guard.locations(for: info, privateHomeItems: nil, home: "/h").contains("/h/Library/Application Support/NewishCorp/"))
        XCTAssertFalse(Presets.originalDataFolders(bundleID: "com.fake.newish", names: []).contains("../escape"))
        let items = Presets.privateHomeItems(for: info)
        XCTAssertTrue(items.contains(".newish-cli"))
        XCTAssertTrue(items.contains(".config/newish"))
        XCTAssertFalse(items.contains("not-hidden"))
        XCTAssertEqual(Presets.singleInstancePorts(for: "com.fake.newish"), [41000 + Int(getuid())], "privileged ports ignored")
        XCTAssertTrue(Knowledge.entries(for: "com.fake.other").isEmpty)
    }

    func testOnlyForTheVersionsItsAbout() {
        Knowledge.override = [Advisories.AppKnowledge(bundleID: "com.fake.v", versions: ">=2.0", dataFolders: ["V2"])]
        XCTAssertFalse(Presets.originalDataFolders(bundleID: "com.fake.v", names: [], version: "1.9 (19)").contains("V2"))
        XCTAssertTrue(Presets.originalDataFolders(bundleID: "com.fake.v", names: [], version: "2.1 (21)").contains("V2"))
        XCTAssertFalse(Presets.originalDataFolders(bundleID: "com.fake.v", names: []).contains("V2"), "no version, no ranged entry")
    }

    /// Knowledge can't claim what everything shares, Parallex's folder or
    /// macOS's, or a port that breaks the arithmetic.
    func testKnowledgeStaysInItsLane() {
        Knowledge.override = [Advisories.AppKnowledge(
            bundleID: "com.fake.greedy", versions: nil,
            dataFolders: ["Parallex", "com.apple.Safari", "CloudDocs", "Greedy"],
            homeFolders: [".config", ".aws", ".SSH", ".local/share", ".local/share/greedy", ".config/greedy", ".greedy"],
            singleInstancePorts: [.init(base: 65535, plusUserID: true), .init(base: 42000, plusUserID: false)]
        )]
        XCTAssertEqual(Knowledge.dataFolders(for: "com.fake.greedy", version: nil), ["Greedy"])
        XCTAssertEqual(Knowledge.homeFolders(for: "com.fake.greedy", version: nil), [".local/share/greedy", ".config/greedy", ".greedy"])
        XCTAssertEqual(Presets.singleInstancePorts(for: "com.fake.greedy"), [42000])
    }

    func testOlderFilesWithoutKnowledgeStillRead() throws {
        let old = #"{"issued": "2026-09-01T00:00:00Z", "apps": [], "messages": []}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Advisories.self, from: Data(old.utf8))
        XCTAssertNil(decoded.knowledge)
    }
}

/// The notices files in the repository are ones Parallex can read.
final class AdvisoriesFileTests: XCTestCase {
    func testTheNoticesFilesDecode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for path in ["advisories/advisories.json", "site/public/advisories.json"] {
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            XCTAssertNoThrow(try decoder.decode(Advisories.self, from: data), path)
        }
    }
}
