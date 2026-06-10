import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ParallexCore

final class IconBuilderTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("icon")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeSourcePNG() throws -> URL {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try XCTUnwrap(context.makeImage())

        let url = tempDir.appendingPathComponent("source.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func assertReadableICNS(_ url: URL) throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertGreaterThan(CGImageSourceGetCount(source), 0)
    }

    func testBuildsBadgedICNSFromImage() throws {
        let png = try makeSourcePNG()
        let out = tempDir.appendingPathComponent("badged.icns")
        try IconBuilder.writeIcon(
            from: .imageFile(png),
            badge: IconBuilder.Badge(text: "W", colorHex: nil, colorSeed: "fake-work"),
            to: out
        )
        try assertReadableICNS(out)
    }

    func testBuildsPlainICNSFromImage() throws {
        let png = try makeSourcePNG()
        let out = tempDir.appendingPathComponent("plain.icns")
        try IconBuilder.writeIcon(from: .imageFile(png), badge: nil, to: out)
        try assertReadableICNS(out)
    }

    func testInvalidBadgeColorThrows() throws {
        let png = try makeSourcePNG()
        let out = tempDir.appendingPathComponent("bad.icns")
        XCTAssertThrowsError(try IconBuilder.writeIcon(
            from: .imageFile(png),
            badge: IconBuilder.Badge(text: "W", colorHex: "#GGGGGG", colorSeed: "x"),
            to: out
        ))
    }

    func testHexColorParsing() {
        XCTAssertNotNil(IconBuilder.color(fromHex: "#FF6B2C"))
        XCTAssertNotNil(IconBuilder.color(fromHex: "ff6b2c"))
        XCTAssertNil(IconBuilder.color(fromHex: "#FFF"))
        XCTAssertNil(IconBuilder.color(fromHex: "nope"))
    }

    func testDefaultColorIsStable() {
        let first = IconBuilder.defaultColorHex(for: "claude-work")
        let second = IconBuilder.defaultColorHex(for: "claude-work")
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("#"))
        XCTAssertEqual(first.count, 7)
    }
}
