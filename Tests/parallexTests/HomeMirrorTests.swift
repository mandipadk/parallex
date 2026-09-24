import XCTest
import ParallexKit

/// A copy's home mirrors yours: links to everything except Library and the
/// app's own items, refreshed at each launch, never touching what the copy
/// made itself.
final class HomeMirrorTests: XCTestCase {
    var tempDir: URL!
    var real: URL!
    var home: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("mirror")
        real = tempDir.appendingPathComponent("real")
        home = tempDir.appendingPathComponent("instance")
        for folder in ["Documents", "Library/Preferences", ".ssh", ".vscode/extensions", ".config/gh", ".config/zed", ".Trash",
                       ".local/bin", ".local/share/zed", ".local/share/fonts"] {
            try fm.createDirectory(at: real.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in [".zshrc", ".gitconfig", ".config/starship.toml"] {
            try "x".write(to: real.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tempDir)
    }

    private func link(_ item: String) -> String? {
        try? fm.destinationOfSymbolicLink(atPath: home.appendingPathComponent(item).path)
    }

    private func exists(_ item: String) -> Bool {
        (try? fm.attributesOfItem(atPath: home.appendingPathComponent(item).path)) != nil
    }

    func testLinksEverythingButLibraryAndTheAppsOwn() {
        HomeMirror.sync(home: home, realHome: real, privateItems: [".vscode", ".config/zed", ".local/share/zed"])
        for item in ["Documents", ".ssh", ".zshrc", ".gitconfig"] {
            XCTAssertEqual(link(item), real.appendingPathComponent(item).path, item)
        }
        XCTAssertFalse(exists("Library"), "the copy's Library is its own")
        XCTAssertFalse(exists(".Trash"))
        XCTAssertFalse(exists(".vscode"), "private: the copy starts without the original's")
        // .config is shared entry by entry, except the app's own.
        XCTAssertNil(link(".config"), "a real folder, so the app's entry can be its own")
        XCTAssertEqual(link(".config/gh"), real.appendingPathComponent(".config/gh").path)
        XCTAssertEqual(link(".config/starship.toml"), real.appendingPathComponent(".config/starship.toml").path)
        XCTAssertFalse(exists(".config/zed"))
        // Deeper too: .local and .local/share are real, the rest linked.
        XCTAssertNil(link(".local"))
        XCTAssertNil(link(".local/share"))
        XCTAssertEqual(link(".local/bin"), real.appendingPathComponent(".local/bin").path)
        XCTAssertEqual(link(".local/share/fonts"), real.appendingPathComponent(".local/share/fonts").path)
        XCTAssertFalse(exists(".local/share/zed"))
    }

    func testFollowsYourHomeAndLeavesTheCopysOwnAlone() throws {
        HomeMirror.sync(home: home, realHome: real, privateItems: [".vscode", ".config/zed"])
        // The copy makes its own things, including a private item.
        try fm.createDirectory(at: home.appendingPathComponent(".vscode/extensions/mine"), withIntermediateDirectories: true)
        try "copy".write(to: home.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: home.appendingPathComponent(".config/zed"), withIntermediateDirectories: true)
        // You add and remove things in your home.
        try "new".write(to: real.appendingPathComponent(".npmrc"), atomically: true, encoding: .utf8)
        try fm.removeItem(at: real.appendingPathComponent(".zshrc"))
        try "real".write(to: real.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        HomeMirror.sync(home: home, realHome: real, privateItems: [".vscode", ".config/zed"])
        XCTAssertEqual(link(".npmrc"), real.appendingPathComponent(".npmrc").path, "new items appear")
        XCTAssertFalse(exists(".zshrc"), "removed items go")
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("notes.txt"), encoding: .utf8), "copy",
                       "the copy's own file wins over yours")
        XCTAssertTrue(exists(".vscode/extensions/mine"))
        XCTAssertNil(link(".config/zed"))
        XCTAssertTrue(exists(".config/zed"))
        // Nothing of yours was touched.
        XCTAssertEqual(try String(contentsOf: real.appendingPathComponent("notes.txt"), encoding: .utf8), "real")
        XCTAssertTrue(fm.fileExists(atPath: real.appendingPathComponent(".vscode/extensions").path))
    }

    /// Copies made before 0.13 had plain links (or none) in their home; an
    /// item that becomes private stops being shared, and .config becomes a
    /// real folder.
    func testTakesOverOlderHomes() throws {
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appendingPathComponent(".vscode"), withDestinationURL: real.appendingPathComponent(".vscode"))
        try fm.createSymbolicLink(at: home.appendingPathComponent(".config"), withDestinationURL: real.appendingPathComponent(".config"))
        // A link somewhere else is the user's own doing; left alone.
        try fm.createSymbolicLink(at: home.appendingPathComponent("elsewhere"), withDestinationURL: tempDir)

        HomeMirror.sync(home: home, realHome: real, privateItems: [".vscode", ".config/zed"])
        XCTAssertFalse(exists(".vscode"))
        XCTAssertNil(link(".config"))
        XCTAssertEqual(link(".config/gh"), real.appendingPathComponent(".config/gh").path)
        XCTAssertEqual(link("elsewhere"), tempDir.path)
        XCTAssertTrue(fm.fileExists(atPath: real.appendingPathComponent(".config/zed").path), "yours untouched")
    }
}
