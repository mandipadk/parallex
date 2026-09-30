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
        XCTAssertTrue(Knowledge.entries(for: "com.fake.v", version: "1.9").isEmpty)
        XCTAssertEqual(Knowledge.entries(for: "com.fake.v", version: "2.1").count, 1)
    }

    func testOlderFilesWithoutKnowledgeStillRead() throws {
        let old = #"{"issued": "2026-09-01T00:00:00Z", "apps": [], "messages": []}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Advisories.self, from: Data(old.utf8))
        XCTAssertNil(decoded.knowledge)
    }
}
