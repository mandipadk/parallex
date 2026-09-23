import AppKit
import SwiftUI

/// Parallex's design tokens. One brand color (vermilion) marks primary
/// actions, selection, and the brand mark; everything else is native
/// neutrals and materials so the app reads as part of macOS. Instance colors
/// are data — small marks, never chrome.
enum Theme {
    // MARK: Color

    /// Vermilion, tuned per appearance: deep enough for white text in light
    /// mode, brighter in dark mode where it sits on graphite.
    static let accentNS = NSColor(name: "ParallexAccent") { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(srgbRed: 1.0, green: 0.42, blue: 0.24, alpha: 1)   // #FF6B3D
            : NSColor(srgbRed: 0.85, green: 0.28, blue: 0.10, alpha: 1)  // #D9481A
    }
    static let accent = Color(nsColor: accentNS)
    static let running = Color(nsColor: .systemGreen)
    static let attention = Color(nsColor: .systemOrange)
    static let failure = Color(nsColor: .systemRed)
    static let hairline = Color(nsColor: .separatorColor)
    static let subtleFill = Color(nsColor: .quaternaryLabelColor).opacity(0.5)

    // MARK: Type
    // SF Pro throughout: Display optical size kicks in automatically at 20pt+.

    enum Font {
        static let hero = SwiftUI.Font.system(size: 34, weight: .bold)
        static let display = SwiftUI.Font.system(size: 26, weight: .semibold)
        static let title = SwiftUI.Font.system(size: 20, weight: .semibold)
        static let headline = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let callout = SwiftUI.Font.system(size: 12)
        static let caption = SwiftUI.Font.system(size: 11)
        /// Section labels: small, heavy, quiet.
        static let label = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let mono = SwiftUI.Font.system(size: 11.5, design: .monospaced)
    }

    // MARK: Layout

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
    }

    enum Radius {
        static let control: CGFloat = 7
        static let tile: CGFloat = 10
        static let panel: CGFloat = 14
    }

    // MARK: Motion
    // Springs for anything that moves; short ease-outs for fades. Views
    // check Reduce Motion and fall back to opacity.

    enum Motion {
        static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.86)
        static let smooth = Animation.spring(response: 0.5, dampingFraction: 0.88)
        static let fade = Animation.easeOut(duration: 0.18)
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("#") {
            cleaned.removeFirst()
        }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            return nil
        }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? .systemBlue
        return String(
            format: "#%02X%02X%02X",
            Int(round(color.redComponent * 255)),
            Int(round(color.greenComponent * 255)),
            Int(round(color.blueComponent * 255))
        )
    }
}

extension Color {
    init(hex: String, fallback: NSColor = .systemGray) {
        self.init(nsColor: NSColor(hex: hex) ?? fallback)
    }
}
