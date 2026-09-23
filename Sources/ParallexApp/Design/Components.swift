import AppKit
import SwiftUI

// MARK: - Buttons

/// Filled with the brand color — one per surface, for the thing to do next.
struct PrimaryButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .system(size: 14, weight: .semibold) : Theme.Font.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 22 : 14)
            .frame(height: large ? 36 : 28)
            .background(Theme.accent.opacity(isEnabled ? 1 : 0.4), in: .rect(cornerRadius: Theme.Radius.control))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(Theme.Motion.fade, value: configuration.isPressed)
    }
}

/// Neutral fill for secondary actions.
struct SecondaryButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .system(size: 14, weight: .medium) : .system(size: 13, weight: .medium))
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .padding(.horizontal, large ? 20 : 12)
            .frame(height: large ? 36 : 28)
            .background(
                Color(nsColor: .quaternaryLabelColor).opacity(configuration.isPressed ? 0.9 : 0.55),
                in: .rect(cornerRadius: Theme.Radius.control)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.fade, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var primaryLarge: PrimaryButtonStyle { PrimaryButtonStyle(large: true) }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
    static var secondaryLarge: SecondaryButtonStyle { SecondaryButtonStyle(large: true) }
}

// MARK: - Icons

/// App icons are expensive to fetch; cache them per path.
@MainActor
enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) {
            return cached
        }
        // Image files (custom icons) are the icon; anything else asks the
        // workspace, which would return a file-type icon for an .icns.
        let imageExtensions: Set<String> = ["icns", "png", "jpg", "jpeg", "tiff", "heic"]
        let icon: NSImage
        if imageExtensions.contains((path as NSString).pathExtension.lowercased()),
           let image = NSImage(contentsOfFile: path) {
            icon = image
        } else if FileManager.default.fileExists(atPath: path) {
            icon = NSWorkspace.shared.icon(forFile: path)
        } else {
            icon = NSWorkspace.shared.icon(for: .applicationBundle)
        }
        cache.setObject(icon, forKey: path as NSString)
        return icon
    }

    /// Wrappers get rebuilt with new icons; drop stale entries.
    static func invalidate(_ path: String) {
        cache.removeObject(forKey: path as NSString)
    }
}

struct AppIcon: View {
    let path: String
    var size: CGFloat = 32

    var body: some View {
        Image(nsImage: IconCache.icon(for: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A ring in the instance's color hugging an app icon's art — the mark of a
/// copy. macOS icon art fills ~80% of the canvas (824 of 1024, corner ~185).
struct InstanceRing: ViewModifier {
    let color: Color
    let size: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            let gap = max(3, size * 0.045)
            RoundedRectangle(cornerRadius: size * 0.18 + gap, style: .continuous)
                .strokeBorder(color, lineWidth: max(2, size * 0.024))
                .padding(size * 0.098 - gap)
        }
    }
}

extension View {
    func instanceRing(_ color: Color, size: CGFloat) -> some View {
        modifier(InstanceRing(color: color, size: size))
    }
}

/// An instance's icon with its color mark — the same color that outlines its
/// windows and colors its menu-bar entry. Large icons wear a ring; small
/// ones a dot.
struct InstanceGlyph: View {
    let iconPath: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        if size >= 48 {
            AppIcon(path: iconPath, size: size).instanceRing(color, size: size)
        } else {
            dotted
        }
    }

    private var dotted: some View {
        AppIcon(path: iconPath, size: size)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(color)
                    .frame(width: max(7, size * 0.3), height: max(7, size * 0.3))
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: max(1.5, size * 0.06)))
                    // Icon art fills ~80% of the canvas; sit on its corner.
                    .offset(x: -size * 0.03, y: -size * 0.03)
            }
    }
}

/// The instance icon as the wrapper will look: app icon plus the letter
/// badge, drawn with the same geometry `IconBuilder` uses.
struct BadgedIconPreview: View {
    let iconPath: String
    let badge: String
    let color: Color
    var size: CGFloat = 64

    var body: some View {
        AppIcon(path: iconPath, size: size)
            .overlay(alignment: .bottomTrailing) {
                if !badge.isEmpty {
                    let diameter = size * 410 / 1024
                    Text(badge.uppercased())
                        .font(.system(size: diameter * (badge.count > 1 ? 0.41 : 0.58), weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: diameter, height: diameter)
                        .background(color, in: .circle)
                        .overlay(Circle().strokeBorder(.white, lineWidth: size * 16 / 1024))
                        .padding(size * 58 / 1024)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(Theme.Motion.snappy, value: badge)
            .animation(Theme.Motion.fade, value: color)
    }
}

// MARK: - Status

enum RunState: Equatable {
    case running
    case stopped
    case attention(String)
    case broken(String)
}

/// A dot and a word. Every state takes the same footprint so rows don't
/// jump as instances start and stop.
struct StatusPill: View {
    let state: RunState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            dot
            Text(label)
                .font(Theme.Font.caption.weight(.medium))
                .foregroundStyle(textColor)
                .lineLimit(1)
        }
        .animation(Theme.Motion.fade, value: state)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var dot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 6, height: 6)
            .phaseAnimator([false, true]) { view, phase in
                view.opacity(state == .running && !reduceMotion && phase ? 0.35 : 1)
            } animation: { _ in
                .easeInOut(duration: 1.4)
            }
    }

    private var label: String {
        switch state {
        case .running: "Running"
        case .stopped: "Not running"
        case .attention(let text), .broken(let text): text
        }
    }

    private var dotColor: Color {
        switch state {
        case .running: Theme.running
        case .stopped: Color(nsColor: .tertiaryLabelColor)
        case .attention: Theme.attention
        case .broken: Theme.failure
        }
    }

    private var textColor: Color {
        switch state {
        case .running: Theme.running
        case .stopped: .secondary
        case .attention: Theme.attention
        case .broken: Theme.failure
        }
    }
}

// MARK: - Sections

/// A titled region of a detail page. No card: a label, a hairline, space.
struct DetailSection<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(.vertical, Theme.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}

/// Toggle with a title and an explanation underneath.
struct ExplainedToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.body)
                Text(detail)
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.l)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Theme.accent)
        }
        .contentShape(.rect)
        .onTapGesture { isOn.toggle() }
        .accessibilityElement(children: .combine)
    }
}

/// A label on the left, a value (optionally monospaced and selectable) on the right.
struct FactRow: View {
    let label: String
    let value: String
    var mono = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text(label)
                .font(Theme.Font.callout)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(mono ? Theme.Font.mono : Theme.Font.callout)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Color picker

/// The instance palette as swatches.
struct ColorSwatchPicker: View {
    @Binding var selection: String
    let palette: [String]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(palette, id: \.self) { hex in
                let selected = hex.caseInsensitiveCompare(selection) == .orderedSame
                Button {
                    selection = hex
                } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 20, height: 20)
                        .overlay {
                            Circle()
                                .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: selected ? 2.5 : 0)
                        }
                        .overlay {
                            Circle()
                                .strokeBorder(Color(hex: hex), lineWidth: selected ? 1.5 : 0)
                                .padding(-3)
                        }
                        .scaleEffect(selected ? 1.05 : 1)
                        .animation(Theme.Motion.snappy, value: selected)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Color \(hex)"))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Brand mark

/// Two offset rounded squares: the original and its copy. `split` goes from
/// 0 (stacked — one app) to 1 (apart — two).
struct ParallelMark: View {
    var size: CGFloat = 64
    var split: CGFloat = 1
    var tint: Color = Theme.accent

    var body: some View {
        let square = size * 0.62
        let offset = size * 0.19 * split
        ZStack {
            RoundedRectangle(cornerRadius: square * 0.26, style: .continuous)
                .strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: max(1.5, size * 0.035))
                .frame(width: square, height: square)
                .offset(x: -offset, y: -offset)
            RoundedRectangle(cornerRadius: square * 0.26, style: .continuous)
                .fill(tint)
                .frame(width: square, height: square)
                .offset(x: offset, y: offset)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
