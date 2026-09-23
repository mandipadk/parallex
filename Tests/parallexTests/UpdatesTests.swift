import CryptoKit
import XCTest
@testable import ParallexCore

final class UpdatesTests: XCTestCase {
    private func releaseJSON(
        tag: String = "v0.9.0", draft: Bool = false, prerelease: Bool = false, assets: [String]? = nil
    ) -> Data {
        let names = assets ?? ["Parallex-0.9.0.zip", "Parallex-0.9.0.zip.sig", "Parallex.dmg"]
        let assetJSON = names.map {
            #"{"name":"\#($0)","browser_download_url":"https://example.com/\#($0)","size":1234}"#
        }.joined(separator: ",")
        return Data("""
        {"tag_name":"\(tag)","body":"## Hello\\n- One","html_url":"https://github.com/mandipadk/parallex/releases/tag/\(tag)",
         "draft":\(draft),"prerelease":\(prerelease),"published_at":"2026-09-24T10:00:00Z","assets":[\(assetJSON)]}
        """.utf8)
    }

    func testParsesLatestRelease() throws {
        let release = try UpdateFeed.parse(releaseJSON())
        XCTAssertEqual(release.version, "0.9.0")
        XCTAssertEqual(release.archiveURL.lastPathComponent, "Parallex-0.9.0.zip")
        XCTAssertEqual(release.signatureURL.lastPathComponent, "Parallex-0.9.0.zip.sig")
        XCTAssertEqual(release.archiveSize, 1234)
        XCTAssertNotNil(release.publishedAt)
        XCTAssertTrue(release.notes.contains("Hello"))
    }

    func testRejectsReleasesWithoutSignedArchive() {
        XCTAssertThrowsError(try UpdateFeed.parse(releaseJSON(assets: ["Parallex-0.9.0.zip", "Parallex.dmg"])))
        XCTAssertThrowsError(try UpdateFeed.parse(releaseJSON(assets: ["Parallex-0.8.9.zip", "Parallex-0.8.9.zip.sig"])),
                             "the archive must match the tag's version")
    }

    func testIgnoresDraftsAndPrereleases() {
        XCTAssertThrowsError(try UpdateFeed.parse(releaseJSON(draft: true)))
        XCTAssertThrowsError(try UpdateFeed.parse(releaseJSON(prerelease: true)))
    }

    func testVersionOrdering() {
        XCTAssertTrue(UpdateFeed.isNewer("0.10.0", than: "0.9.3"))
        XCTAssertTrue(UpdateFeed.isNewer("1.0", than: "0.99.99"))
        XCTAssertFalse(UpdateFeed.isNewer("0.8.0", than: "0.8.0"))
        XCTAssertFalse(UpdateFeed.isNewer("0.8", than: "0.8.0"))
        XCTAssertFalse(UpdateFeed.isNewer("0.7.9", than: "0.8.0"))
    }

    func testSignatureVerification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let archive = Data("the app".utf8)
        let signature = try key.signature(for: archive).base64EncodedString()

        XCTAssertTrue(UpdateSignature.verify(archive, signature: signature + "\n", publicKey: publicKey))
        XCTAssertFalse(UpdateSignature.verify(Data("tampered".utf8), signature: signature, publicKey: publicKey))
        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertFalse(UpdateSignature.verify(archive, signature: signature, publicKey: otherKey))
        XCTAssertFalse(UpdateSignature.verify(archive, signature: "not base64", publicKey: publicKey))
    }

    func testBuiltInKeyIsWellFormed() throws {
        let raw = try XCTUnwrap(Data(base64Encoded: UpdateSignature.publicKey))
        XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: raw))
    }
}
