import CryptoKit
import XCTest
@testable import ParallexCore

/// Signed notices: only the key's owner can publish them, and they say
/// what they should about the right versions.
final class AdvisoriesTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    private let file = Data("""
    {"issued": "2026-09-24T12:00:00Z",
     "apps": [
       {"bundleID": "com.microsoft.teams2", "versions": ">=25000", "level": "unsupported",
        "message": "Copies of Teams quit at launch.", "website": "https://teams.microsoft.com"},
       {"bundleID": "com.microsoft.teams2", "level": "warning", "message": "Calls share the camera with the original."}
     ],
     "messages": [
       {"id": "window-bug", "parallex": "0.16.1...0.17.0", "title": "Update Parallex", "body": "0.17.1 fixes the tall window."}
     ]}
    """.utf8)

    private func sign(_ data: Data) throws -> String {
        try key.signature(for: data).base64EncodedString()
    }

    func testOnlySignedNoticesAreRead() throws {
        let good = try sign(Advisories.signingContext + file)
        XCTAssertNotNil(Advisories.verify(file, signature: good, publicKey: publicKey))

        var tampered = file
        tampered[tampered.index(tampered.startIndex, offsetBy: 40)] = UInt8(ascii: "X")
        XCTAssertNil(Advisories.verify(tampered, signature: good, publicKey: publicKey), "changed after signing")
        XCTAssertNil(Advisories.verify(file, signature: try sign(file), publicKey: publicKey), "signed without the notices label (an update's signature)")
        XCTAssertNil(Advisories.verify(file, signature: good), "someone else's key")
    }

    func testNoticesAndMessagesForTheRightVersions() throws {
        let advisories = try XCTUnwrap(Advisories.verify(file, signature: try sign(Advisories.signingContext + file), publicKey: publicKey))
        XCTAssertEqual(advisories.notices(bundleID: "com.microsoft.teams2", version: "25123.1 (25123.1)").map(\.level), ["unsupported", "warning"])
        XCTAssertEqual(advisories.notices(bundleID: "com.microsoft.teams2", version: "24100.2").map(\.level), ["warning"])
        XCTAssertEqual(advisories.notices(bundleID: "com.tinyspeck.slackmacgap", version: "4.43").count, 0)
        XCTAssertEqual(advisories.messages(forParallex: "0.17.0").map(\.id), ["window-bug"])
        XCTAssertEqual(advisories.messages(forParallex: "0.17.1").count, 0)
    }

    /// The file the site serves verifies with the key in the app: edited
    /// without `make advisories`, this fails before anyone gets it.
    func testThePublishedNoticesAreSigned() throws {
        let site = Fixtures.repositoryRoot.appendingPathComponent("site/public")
        let data = try Data(contentsOf: site.appendingPathComponent("advisories.json"))
        let signature = try String(contentsOf: site.appendingPathComponent("advisories.json.sig"), encoding: .utf8)
        XCTAssertNotNil(Advisories.verify(data, signature: signature), "run make advisories")
        let source = try Data(contentsOf: Fixtures.repositoryRoot.appendingPathComponent("advisories/advisories.json"))
        XCTAssertEqual(source, data, "advisories/advisories.json changed since it was signed: run make advisories")
    }

    func testVersionRanges() {
        XCTAssertTrue(VersionRange.contains(nil, "1.0"))
        XCTAssertTrue(VersionRange.contains("*", nil))
        XCTAssertTrue(VersionRange.contains("<4.44", "4.43.1"))
        XCTAssertFalse(VersionRange.contains("<4.44", "4.44"))
        XCTAssertTrue(VersionRange.contains("<=4.44", "4.44"))
        XCTAssertTrue(VersionRange.contains(">=2", "10.0"))
        XCTAssertTrue(VersionRange.contains("1.2...1.4", "1.3.9"))
        XCTAssertFalse(VersionRange.contains("1.2...1.4", "1.4.1"))
        XCTAssertTrue(VersionRange.contains("1.0, >=3", "3.1"))
        XCTAssertFalse(VersionRange.contains("1.0", nil), "a range needs a version to match")
        XCTAssertTrue(VersionRange.contains("<25.2", "25.1 (25123.4567)"), "the build is left out")
        XCTAssertFalse(VersionRange.contains(">=25.2", "25.1 (25123.4567)"))
        for malformed in ["1.0...", "...2.0", ">", ">=", "1.0,,2.0", "abc"] {
            XCTAssertFalse(VersionRange.isValid(malformed), malformed)
            XCTAssertFalse(VersionRange.contains(malformed, "1.5"), "\(malformed) matches nothing")
        }
        XCTAssertTrue(VersionRange.isValid("1.0...2.0, >=3, 4.2"))
    }
}
