import AppKit
import ParallexKit
import SwiftUI

/// What changed in each release, written for people rather than scraped
/// from commits. The newest release comes first.
enum ReleaseHighlights {
    struct Highlight: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    struct Release {
        let version: String
        let highlights: [Highlight]
    }

    static let releases: [Release] = [
        Release(version: "0.10.0", highlights: [
            Highlight(
                symbol: "rectangle.stack",
                title: "Workspaces",
                detail: "Group the instances you use together, like Work and Personal, and open them all at once with one shortcut."
            ),
            Highlight(
                symbol: "link",
                title: "Open from anywhere",
                detail: "parallex:// links open an instance or a workspace from Shortcuts, launchers, scripts or a bookmark."
            ),
            Highlight(
                symbol: "plus.square.on.square",
                title: "Duplicate",
                detail: "Make another instance with the same settings, starting fresh or with a copy of its data."
            ),
        ]),
        Release(version: "0.9.0", highlights: [
            Highlight(
                symbol: "square.stack.3d.up",
                title: "Every copy gets its own Library",
                detail: "Copies of native apps now keep their sign-ins, caches and web storage to themselves. Nothing is shared with the original."
            ),
            Highlight(
                symbol: "checkmark.shield",
                title: "Verified, not assumed",
                detail: "Verify Isolation now flags anything a copy leaves in your real Library."
            ),
            Highlight(
                symbol: "trash",
                title: "Clean removal",
                detail: "Removing a copy takes its preferences and window state with it to the Trash."
            ),
        ]),
        Release(version: "0.8.0", highlights: [
            Highlight(
                symbol: "command",
                title: "A shortcut for every instance",
                detail: "Press it from anywhere to open the instance, bring it forward, or hide it again."
            ),
            Highlight(
                symbol: "bell.badge",
                title: "Notifications only when they matter",
                detail: "A copy that's behind its app, an app that went missing, a failed repair. Nothing else."
            ),
            Highlight(
                symbol: "arrow.down.circle",
                title: "Updates, built in",
                detail: "Parallex checks once a day and updates itself in one click. Every update is signed."
            ),
            Highlight(
                symbol: "rectangle.stack",
                title: "Faster switching",
                detail: "In the switcher, ⌘1 to ⌘9 jump straight to an instance."
            ),
        ]),
    ]

    static var current: Release? {
        releases.first { $0.version == ParallexConfig.version } ?? releases.first
    }
}

/// Shown once after Parallex updates, and from Settings › About.
struct WhatsNewView: View {
    var onContinue: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Theme.Space.m) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                    .scaleEffect(appeared || reduceMotion ? 1 : 0.85)
                    .opacity(appeared ? 1 : 0)
                VStack(spacing: 6) {
                    Text("What's new in Parallex")
                        .font(Theme.Font.display)
                    Text("Version \(ReleaseHighlights.current?.version ?? ParallexConfig.version)")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .opacity(appeared ? 1 : 0)
            }
            .padding(.top, Theme.Space.xxl)
            .padding(.bottom, Theme.Space.xl)

            VStack(alignment: .leading, spacing: Theme.Space.l) {
                ForEach(Array((ReleaseHighlights.current?.highlights ?? []).enumerated()), id: \.element.id) { index, item in
                    HighlightRow(item: item)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared || reduceMotion ? 0 : 10)
                        .animation(
                            reduceMotion ? Theme.Motion.fade : Theme.Motion.smooth.delay(0.12 + Double(index) * 0.06),
                            value: appeared
                        )
                }
            }
            .padding(.horizontal, Theme.Space.xxl + Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: Theme.Space.xl)

            Button("Continue", action: onContinue)
                .keyboardShortcut(.defaultAction)
                .prominentAction()
                .padding(.bottom, Theme.Space.xl)
        }
        .frame(width: 500, height: 560)
        .background(WindowGlassBackground().ignoresSafeArea())
        .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.smooth, value: appeared)
        .onAppear { appeared = true }
        .tint(Theme.accent)
    }
}

private struct HighlightRow: View {
    let item: ReleaseHighlights.Highlight

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m + 2) {
            Image(systemName: item.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.accent.opacity(0.12), in: .rect(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(Theme.Font.headline)
                Text(item.detail)
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
