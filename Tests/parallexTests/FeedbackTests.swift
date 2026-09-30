import XCTest
@testable import ParallexCore
import ParallexKit

/// A note from Something's Off says what its sender wrote, and about the
/// instance only what's safe to.
final class FeedbackTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("feedback")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func manifest(_ name: String, app: String, bundleID: String) -> InstanceManifest {
        InstanceManifest(
            name: name, slug: Slug.make(name), bundleIdentifier: "com.parallex.instance.\(Slug.make(name))",
            targetApp: app, targetBinary: app + "/Contents/MacOS/x", wrapperPath: "/Volumes/Work/Apps/\(name).app",
            mode: .home, preset: nil, arguments: [], environment: [:], homeSymlinks: nil, createdAt: Date(),
            parallexVersion: ParallexConfig.version, targetBundleID: bundleID, settings: InstanceSettings(),
            clone: .init(bundleIdentifier: "com.parallex.instance.\(Slug.make(name))", sourceVersion: "4.43.1 (4.43.1)", usesLauncher: true)
        )
    }

    func testANoteSaysWhatWasWrittenAndNothingPersonal() {
        let secret = manifest("Acme Secret Client", app: "/Volumes/Work/Secret Tool.app", bundleID: "com.acme.secret")
        let note = Feedback.make(message: "  It closes right away.  ", contact: "  ", about: secret)
        XCTAssertEqual(note.message, "It closes right away.")
        XCTAssertNil(note.contact, "a blank address isn't sent")
        XCTAssertEqual(note.instance?.app, "other")
        XCTAssertNil(note.instance?.appVersion, "no version for an app that isn't well-known")
        XCTAssertEqual(note.instance?.facts.isolation, "unchecked")
        let json = String(decoding: Feedback.json(note), as: UTF8.self)
        for leak in ["Acme", "Secret", "/Volumes", "com.acme"] {
            XCTAssertFalse(json.contains(leak), "\(leak) left the Mac")
        }
        XCTAssertTrue(json.contains("\"guard\""), "the server reads it as guard")
    }

    func testAWellKnownAppIsNamed() {
        let slack = manifest("Work", app: "/Applications/Slack.app", bundleID: "com.tinyspeck.slackmacgap")
        let note = Feedback.make(message: "Notifications stopped", contact: "me@example.com", about: slack)
        XCTAssertEqual(note.instance?.app, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(note.instance?.kind, "copy")
        XCTAssertEqual(note.contact, "me@example.com")
        XCTAssertNil(Feedback.make(message: "In general", contact: nil, about: nil).instance)
        XCTAssertNil(Feedback.make(message: "Hi", contact: "a@b.com?cc=x@y.com", about: nil).contact, "only a plain address")
    }
}
