import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Builds the wrapper's `app.icns`, optionally compositing a colored badge
/// (1–2 characters, bottom-right) so instances are distinguishable in the
/// Dock. Pure ImageIO/CoreGraphics/CoreText; AppKit is only touched for the
/// NSWorkspace fallback when the target keeps its icon in Assets.car.
public enum IconBuilder {
    struct Badge {
        var text: String
        var colorHex: String?
        /// Seed for the deterministic default color (the instance slug).
        var colorSeed: String
    }

    enum IconSource {
        /// The target's .icns file — copied verbatim when there's no badge.
        case icnsFile(URL)
        /// Any ImageIO-readable image (custom icon, png etc.).
        case imageFile(URL)
        /// Ask NSWorkspace to render the app's icon (Assets.car-only apps).
        case appGeneric(URL)
    }

    static func writeIcon(from source: IconSource, badge: Badge?, to outputICNS: URL) throws {
        // Fast path: no compositing needed, the icns is usable as-is.
        if badge == nil, case .icnsFile(let url) = source {
            try? FileManager.default.removeItem(at: outputICNS)
            try FileManager.default.copyItem(at: url, to: outputICNS)
            return
        }

        guard var image = loadImage(from: source) else {
            throw ParallexError("Could not load an icon image for the wrapper.")
        }
        if let badge {
            image = try composite(base: image, badge: badge)
        }
        try writeICNS(image, to: outputICNS)
    }

    // MARK: - Loading

    private static func loadImage(from source: IconSource) -> CGImage? {
        switch source {
        case .icnsFile(let url), .imageFile(let url):
            return largestImage(at: url) ?? genericIcon(for: url)
        case .appGeneric(let url):
            return genericIcon(for: url)
        }
    }

    /// icns files carry many renditions; pick the largest.
    private static func largestImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        var bestIndex = 0
        var bestWidth = 0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int
            else { continue }
            if width > bestWidth {
                bestWidth = width
                bestIndex = index
            }
        }
        return CGImageSourceCreateImageAtIndex(source, bestIndex, nil)
    }

    private static func genericIcon(for url: URL) -> CGImage? {
        nonisolated(unsafe) var result: CGImage?
        onMainThread {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 1024, height: 1024)
            var rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
            result = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        return result
    }

    // MARK: - Badge compositing

    private static let canvasSize = 1024

    /// Instance colors: distinct at a glance in the Dock, window outlines, and
    /// lists, and dark enough for white badge text. Selection for instances
    /// without a chosen color is a stable hash of the slug (Swift's hashValue
    /// is randomized per process, so it can't be used here).
    public static let palette = ["#0A84FF", "#30A46C", "#0FA3B1", "#D99A0B", "#E93D82", "#A1775A", "#6E6E73"]

    public static func defaultColorHex(for seed: String) -> String {
        var hash: UInt64 = 5381
        for byte in seed.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }

    static func color(fromHex hex: String) -> CGColor? {
        var cleaned = hex.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("#") {
            cleaned.removeFirst()
        }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            return nil
        }
        return CGColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func makeContext(size: Int) throws -> CGContext {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: size,
                  height: size,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw ParallexError("Could not create a graphics context for icon rendering.")
        }
        context.interpolationQuality = .high
        return context
    }

    private static func composite(base: CGImage, badge: Badge) throws -> CGImage {
        let size = CGFloat(canvasSize)
        let context = try makeContext(size: canvasSize)

        // Base icon, aspect-fit and centered.
        let baseWidth = CGFloat(base.width)
        let baseHeight = CGFloat(base.height)
        let scale = min(size / baseWidth, size / baseHeight)
        let drawSize = CGSize(width: baseWidth * scale, height: baseHeight * scale)
        context.draw(base, in: CGRect(
            x: (size - drawSize.width) / 2,
            y: (size - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        ))

        // Badge circle, bottom-right, with a white ring for contrast.
        let radius: CGFloat = 205
        let margin: CGFloat = 58
        let center = CGPoint(x: size - margin - radius, y: margin + radius)
        let circle = CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        )
        let hex = badge.colorHex ?? defaultColorHex(for: badge.colorSeed)
        guard let fill = color(fromHex: hex) else {
            throw ParallexError("Invalid badge color '\(hex)' — expected #RRGGBB.")
        }
        context.setFillColor(fill)
        context.fillEllipse(in: circle)
        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.setLineWidth(16)
        context.strokeEllipse(in: circle.insetBy(dx: 8, dy: 8))

        // Badge text, optically centered in the circle.
        let text = badge.text.uppercased()
        let fontSize: CGFloat = text.count > 1 ? 170 : 240
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)
            ?? CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textMatrix = .identity
        context.textPosition = .zero
        let bounds = CTLineGetImageBounds(line, context)
        context.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
        CTLineDraw(line, context)

        guard let image = context.makeImage() else {
            throw ParallexError("Could not render the badged icon.")
        }
        return image
    }

    // MARK: - icns output

    /// Renditions iconutil expects in a .iconset directory.
    private static let renditions: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    private static func writeICNS(_ image: CGImage, to outputICNS: URL) throws {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("parallex-icon-\(UUID().uuidString)")
        let iconset = workDir.appendingPathComponent("app.iconset", isDirectory: true)
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        for (name, pixels) in renditions {
            let context = try makeContext(size: pixels)
            context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
            guard let scaled = context.makeImage() else {
                throw ParallexError("Could not scale icon to \(pixels)px.")
            }
            let pngURL = iconset.appendingPathComponent("\(name).png")
            guard let destination = CGImageDestinationCreateWithURL(
                pngURL as CFURL, UTType.png.identifier as CFString, 1, nil
            ) else {
                throw ParallexError("Could not write \(pngURL.lastPathComponent).")
            }
            CGImageDestinationAddImage(destination, scaled, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw ParallexError("Could not write \(pngURL.lastPathComponent).")
            }
        }

        try? FileManager.default.removeItem(at: outputICNS)
        try Shell.run("/usr/bin/iconutil", [
            "--convert", "icns", "--output", outputICNS.path, iconset.path,
        ])
    }
}
