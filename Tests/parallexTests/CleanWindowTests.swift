import XCTest
@testable import ParallexCore

final class CleanWindowTests: XCTestCase {
    func testFindsTheLinkInWhatWasSelected() {
        XCTAssertEqual(CleanWindow.link(in: "https://example.com/a?b=c")?.absoluteString, "https://example.com/a?b=c")
        XCTAssertEqual(CleanWindow.link(in: "  see https://example.com/x for details ")?.host, "example.com")
        XCTAssertEqual(CleanWindow.link(in: "example.com")?.host, "example.com")
    }

    func testOpensOnlyWebAddresses() {
        XCTAssertNil(CleanWindow.link(in: "file:///etc/passwd"))
        XCTAssertNil(CleanWindow.link(in: "slack://open"))
        XCTAssertNil(CleanWindow.link(in: "just some words"))
        XCTAssertNil(CleanWindow.link(in: ""))
    }

    func testSkipsLinksThatArentWebAddresses() {
        XCTAssertEqual(CleanWindow.link(in: "write me@example.org or see https://example.com")?.host, "example.com")
        XCTAssertNil(CleanWindow.link(in: "write me@example.org"))
        XCTAssertEqual(CleanWindow.link(in: ["file:///Volumes/Work/a.txt", "https://example.com"])?.host, "example.com")
        XCTAssertNil(CleanWindow.link(in: ["file:///Volumes/Work/a.txt"]))
    }

    func testNamesDontCollide() {
        XCTAssertEqual(CleanWindow.freeName(taken: []), "Clean Window")
        XCTAssertEqual(CleanWindow.freeName(taken: ["Clean Window", "Clean Window 2"]), "Clean Window 3")
    }
}
