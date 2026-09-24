import AppKit
import Foundation

/// A web instance's icon: the site's own, or a letter tile in the
/// instance's color when the site doesn't offer one worth using.
public enum WebIcon {
    /// The site's best icon, saved as a PNG file; nil when there's none
    /// (or no network). Blocks for at most a few seconds: call it off the
    /// main thread.
    public static func fetch(for site: URL, timeout: TimeInterval = 6) -> URL? {
        let deadline = Date().addingTimeInterval(timeout)
        var candidates: [URL] = []
        if let html = download(site, deadline: deadline, limit: 1_000_000).flatMap({ String(data: $0, encoding: .utf8) }) {
            candidates += declaredIcons(in: html, base: site)
        }
        if let root = URL(string: "/", relativeTo: site)?.absoluteURL {
            candidates += ["apple-touch-icon.png", "apple-touch-icon-precomposed.png", "favicon.ico"]
                .compactMap { URL(string: $0, relativeTo: root)?.absoluteURL }
        }
        // The sharpest one wins (a 57-pixel icon looks soft in the Dock).
        var best: (image: NSImage, side: CGFloat)?
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.absoluteString).inserted {
            guard Date() < deadline,
                  let data = download(candidate, deadline: deadline, limit: 2_000_000),
                  let image = NSImage(data: data)
            else { continue }
            let side = largestSide(of: image)
            if side >= 48, side > (best?.side ?? 0) {
                best = (image, side)
            }
            if side >= 256 { break }
        }
        return best.flatMap { save(appTile($0.image)) }
    }

    /// macOS app icons are a rounded tile, 824 of 1024 pixels, centered.
    private static let tileRect = NSRect(x: 100, y: 100, width: 824, height: 824)
    private static let tileRadius: CGFloat = 185

    /// A site's icon made to sit among app icons: a square one fills the
    /// tile; a logo with transparent edges sits on a white one.
    static func appTile(_ icon: NSImage) -> NSImage {
        let logo = hasTransparentEdges(icon)
        return NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
            let tile = NSBezierPath(roundedRect: tileRect, xRadius: tileRadius, yRadius: tileRadius)
            NSGraphicsContext.saveGraphicsState()
            tile.addClip()
            if logo {
                NSColor.white.setFill()
                tile.fill()
                icon.draw(in: tileRect.insetBy(dx: 132, dy: 132))
            } else {
                icon.draw(in: tileRect)
            }
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    /// Whether the icon's border is see-through (a logo rather than a tile).
    static func hasTransparentEdges(_ icon: NSImage) -> Bool {
        let side = 32
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = icon.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = { context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side)); return context.data }()
        else { return false }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var clear = 0
        var border = 0
        for y in 0..<side {
            for x in 0..<side where x == 0 || y == 0 || x == side - 1 || y == side - 1 {
                border += 1
                if pixels[(y * side + x) * 4 + 3] < 200 { clear += 1 }
            }
        }
        // Rounded corners alone leave a few clear pixels; a logo, many.
        return clear * 4 > border
    }

    /// `<link rel="apple-touch-icon" …>` first, then `<link rel="icon" …>`
    /// by declared size, largest first (SVGs left out: they don't always
    /// draw as app icons).
    static func declaredIcons(in html: String, base: URL) -> [URL] {
        var found: [(url: URL, rank: Int)] = []
        let tags = html.matches(of: /<link\b[^>]*>/.ignoresCase())
        for tag in tags {
            let text = String(tag.output)
            guard let rel = attribute("rel", in: text)?.lowercased(), rel.contains("icon"),
                  let href = attribute("href", in: text), !href.lowercased().hasSuffix(".svg"),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  url.scheme == "https" || url.scheme == "http"
            else { continue }
            let size = attribute("sizes", in: text)?.split(separator: "x").first.flatMap { Int($0) } ?? 0
            let rank = (rel.contains("apple-touch-icon") ? 10_000 : 0) + size
            found.append((url, rank))
        }
        return found.sorted { $0.rank > $1.rank }.map(\.url)
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = try? Regex("\(name)\\s*=\\s*[\"']([^\"']*)[\"']").ignoresCase()
        guard let pattern, let match = tag.firstMatch(of: pattern), let value = match.output[1].substring else { return nil }
        return String(value)
    }

    /// A rounded tile in the instance's color with the name's first letter.
    public static func monogram(for name: String, colorHex: String) -> URL? {
        let image = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: tileRect, xRadius: tileRadius, yRadius: tileRadius)
            (IconBuilder.color(fromHex: colorHex).flatMap { NSColor(cgColor: $0) } ?? .systemBlue).setFill()
            tile.fill()
            let letter = String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 440, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let text = NSAttributedString(string: letter.isEmpty ? "W" : letter, attributes: attributes)
            let bounds = text.size()
            text.draw(at: NSPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2))
            return true
        }
        return save(image)
    }

    private static func largestSide(of image: NSImage) -> CGFloat {
        let pixels = image.representations.map { CGFloat(max($0.pixelsWide, $0.pixelsHigh)) }.max() ?? 0
        return max(pixels, max(image.size.width, image.size.height))
    }

    private static func save(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("parallex-web-icon-\(UUID().uuidString).png")
        return (try? png.write(to: file)) != nil ? file : nil
    }

    private static func download(_ url: URL, deadline: Date, limit: Int) -> Data? {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        var request = URLRequest(url: url, timeoutInterval: remaining)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        nonisolated(unsafe) var result: Data?
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, data.count <= limit, (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false {
                result = data
            }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + remaining) == .timedOut {
            task.cancel()
        }
        return result
    }
}
