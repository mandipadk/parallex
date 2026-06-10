import XCTest
@testable import ParallexCore

final class SlugTests: XCTestCase {
    func testBasicNames() {
        XCTAssertEqual(Slug.make("Claude Work"), "claude-work")
        XCTAssertEqual(Slug.make("Chrome Dev 2"), "chrome-dev-2")
        XCTAssertEqual(Slug.make("simple"), "simple")
    }

    func testDiacriticsAreFolded() {
        XCTAssertEqual(Slug.make("Émile's App"), "emile-s-app")
        XCTAssertEqual(Slug.make("Über Tool"), "uber-tool")
    }

    func testPunctuationCollapsesToSingleDash() {
        XCTAssertEqual(Slug.make("a  --  b"), "a-b")
        XCTAssertEqual(Slug.make("Hello!!! World???"), "hello-world")
    }

    func testEdgesAreTrimmed() {
        XCTAssertEqual(Slug.make("  padded  "), "padded")
        XCTAssertEqual(Slug.make("--dashes--"), "dashes")
    }

    func testDegenerateNames() {
        XCTAssertEqual(Slug.make(""), "")
        XCTAssertEqual(Slug.make("!!!"), "")
        XCTAssertEqual(Slug.make("🚀🚀🚀"), "")
    }
}
