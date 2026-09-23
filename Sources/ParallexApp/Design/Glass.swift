import AppKit
import SwiftUI

// Liquid Glass on macOS 26, the closest material look before it. Every
// surface that floats (panels, tiles, name tags, capsule buttons) goes
// through these so the app has one consistent depth language.

extension View {
    /// A floating glass surface.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = Theme.Radius.panel, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            self
                .background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Theme.hairline))
        }
    }

    /// Glass shaped as a capsule (name tags, chips).
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self
                .background(.regularMaterial, in: .capsule)
                .overlay(Capsule().strokeBorder(Theme.hairline))
        }
    }

    /// The prominent action: tinted glass capsule on macOS 26, a solid
    /// capsule before it.
    @ViewBuilder
    func prominentAction() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent).tint(Theme.accent).controlSize(.extraLarge)
        } else {
            self.buttonStyle(CapsuleButtonStyle(prominent: true))
        }
    }

    /// A quiet capsule action next to a prominent one.
    @ViewBuilder
    func quietAction() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass).controlSize(.extraLarge)
        } else {
            self.buttonStyle(CapsuleButtonStyle(prominent: false))
        }
    }
}

/// Capsule buttons for systems without Liquid Glass.
struct CapsuleButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 22)
            .frame(height: 38)
            .background {
                if prominent {
                    Capsule().fill(Theme.accent.opacity(isEnabled ? 1 : 0.4))
                } else {
                    Capsule().fill(.regularMaterial)
                        .overlay(Capsule().strokeBorder(Theme.hairline))
                }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.fade, value: configuration.isPressed)
    }
}

/// The desktop showing through the window, frosted — behind-window vibrancy.
struct WindowGlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
