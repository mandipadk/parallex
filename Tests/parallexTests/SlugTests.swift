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

    func testInstanceSlugsWorkForAnyName() {
        XCTAssertEqual(Slug.forInstance(named: "Claude Work"), "claude-work")
        XCTAssertEqual(Slug.forInstance(named: "Работа"), "rabota")
        XCTAssertEqual(Slug.forInstance(named: "Работа 2"), "rabota-2")
        XCTAssertEqual(Slug.forInstance(named: "2024"), "2024")
        XCTAssertFalse(Slug.forInstance(named: "日本語").isEmpty)
        let emoji = Slug.forInstance(named: "🚀🚀")
        XCTAssertTrue(emoji.hasPrefix("instance-"))
        XCTAssertEqual(emoji, Slug.forInstance(named: "🚀🚀"), "stable for the same name")
        XCTAssertNotEqual(emoji, Slug.forInstance(named: "🚀🛸"))
    }
}
