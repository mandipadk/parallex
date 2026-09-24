import XCTest
@testable import ParallexCore

final class ParallexLinkTests: XCTestCase {
    func testParsesEachAction() {
        XCTAssertEqual(ParallexLink(URL(string: "parallex://open/Claude%20Work")!), .open(instance: "Claude Work"))
        XCTAssertEqual(ParallexLink(URL(string: "PARALLEX://Workspace/Work")!), .workspace("Work"))
        XCTAssertEqual(ParallexLink(URL(string: "parallex://show/claude-work")!), .show(instance: "claude-work"))
        XCTAssertEqual(ParallexLink(URL(string: "parallex://new?app=Obsidian")!), .new(app: "Obsidian"))
        XCTAssertEqual(ParallexLink(URL(string: "parallex://new")!), .new(app: nil))
    }

    func testRejectsIncompleteOrForeignLinks() {
        XCTAssertNil(ParallexLink(URL(string: "parallex://open/")!))
        XCTAssertNil(ParallexLink(URL(string: "parallex://quit/Work")!), "nothing destructive")
        XCTAssertNil(ParallexLink(URL(string: "parallex://remove/Work")!))
        XCTAssertNil(ParallexLink(URL(string: "https://open/Work")!))
        XCTAssertNil(ParallexLink(URL(string: "parallex://new?app=/private/tmp/Evil.app")!), "no paths")
        XCTAssertNil(ParallexLink(URL(string: "parallex://new?app=~/Downloads/Evil.app")!))
    }

    func testDecodesExactlyOnce() {
        XCTAssertEqual(ParallexLink(URL(string: "parallex://open/Build%2541")!), .open(instance: "Build%41"))
    }

    func testBuildsLinksThatRoundTrip() {
        for name in ["Claude Work", "Straße Café", "日本語", "A & B", "50% done"] {
            XCTAssertEqual(ParallexLink(ParallexLink.url(opening: name)), .open(instance: name))
            XCTAssertEqual(ParallexLink(ParallexLink.url(openingWorkspace: name)), .workspace(name))
        }
    }
}
