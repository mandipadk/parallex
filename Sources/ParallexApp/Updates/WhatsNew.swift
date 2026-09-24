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
        Release(version: "0.20.0", highlights: [
            Highlight(
                symbol: "hand.raised",
                title: "What leaves your Mac, in plain words",
                detail: "Update checks now go to parallex.mandip.dev and count active Macs: just the version, macOS, chip and day, never who. Settings › About and parallex.mandip.dev/privacy say exactly what's sent."
            ),
        ]),
        Release(version: "0.19.0", highlights: [
            Highlight(
                symbol: "moon.zzz",
                title: "Quit when unused",
                detail: "An instance can quit itself after 15 minutes, an hour or four of not being in front, freeing its memory. Not while it's playing sound. In its Launch section."
            ),
            Highlight(
                symbol: "point.3.connected.trianglepath.dotted",
                title: "Claude instances can share MCP servers",
                detail: "Turn on Share MCP servers and an instance uses the ones set up in your other Claude, while sign-ins, chats and settings stay separate."
            ),
        ]),
        Release(version: "0.18.0", highlights: [
            Highlight(
                symbol: "square.stack.3d.up",
                title: "Parallex in Shortcuts",
                detail: "Open or quit an instance or a whole workspace, or check if one is running, from Shortcuts and Siri: \"Open a workspace in Parallex\"."
            ),
            Highlight(
                symbol: "moon",
                title: "A workspace for each Focus",
                detail: "In System Settings › Focus, add Parallex as a Focus filter: turning on Work opens your Work workspace, and can quit the others."
            ),
        ]),
        Release(version: "0.17.0", highlights: [
            Highlight(
                symbol: "trash",
                title: "Throwaway instances",
                detail: "For a one-off sign-in or a quick test: once it's been opened and quits, it goes to the Trash with its data. ⋯ › New Throwaway Copy, or turn on Throwaway."
            ),
            Highlight(
                symbol: "memorychip",
                title: "Memory at a glance",
                detail: "Each running instance shows the memory it uses, helpers included: in the sidebar, the menu bar, and each workspace's total."
            ),
        ]),
        Release(version: "0.16.1", highlights: [
            Highlight(
                symbol: "dock.rectangle",
                title: "Hide a copy from the Dock",
                detail: "For copies you keep running in the background: no Dock icon or ⌘-Tab entry. Open it from its menu bar icon or shortcut. In the instance's Launch section."
            ),
            Highlight(
                symbol: "heart",
                title: "Support Parallex",
                detail: "Parallex is free and made by a student. If it helps you, Settings › About has GitHub Sponsors and Ko-fi. First goal: signing it with Apple."
            ),
        ]),
        Release(version: "0.16.0", highlights: [
            Highlight(
                symbol: "globe",
                title: "Websites as apps",
                detail: "Teams, Outlook, a second Gmail: any site becomes an app with its own Dock icon, sign-in and notifications. New Instance › A website."
            ),
            Highlight(
                symbol: "app.badge",
                title: "Unread counts in the Dock",
                detail: "A site's unread count shows on its Dock icon, its notifications arrive like any app's, and links to other sites open in your browser."
            ),
            Highlight(
                symbol: "text.bubble",
                title: "Say how an app works",
                detail: "An instance's ⋯ menu › Report How It Works opens a GitHub report with the app and setup filled in, so the next person knows what to expect."
            ),
        ]),
        Release(version: "0.15.0", highlights: [
            Highlight(
                symbol: "rectangle.stack.badge.plus",
                title: "A whole workspace at once",
                detail: "Name it, pick a color, tick the apps. Parallex makes every copy, each the right way, in that workspace's color."
            ),
            Highlight(
                symbol: "paintpalette",
                title: "Workspaces have a color",
                detail: "Give one to a workspace and its instances, so Work looks like Work: in the sidebar, the window outlines and the icons."
            ),
        ]),
        Release(version: "0.14.0", highlights: [
            Highlight(
                symbol: "arrow.triangle.branch",
                title: "Links follow you",
                detail: "A link you click in a work instance opens in your work browser, or a Chrome profile, or a browser instance. Choose it on each workspace, and turn it on in Settings › Links."
            ),
            Highlight(
                symbol: "globe",
                title: "Sites that always open in one place",
                detail: "Send northwind.com to the client's browser, github.com to Chrome. Everything else opens in the browser you had, as before."
            ),
        ]),
        Release(version: "0.13.0", highlights: [
            Highlight(
                symbol: "folder.badge.person.crop",
                title: "Hidden folders stay separate",
                detail: "New copies keep the folders their app makes in your home, like ~/.vscode, to themselves, and their own encryption key in your keychain."
            ),
            Highlight(
                symbol: "checkmark.seal",
                title: "Verified here",
                detail: "Apps whose instance passed an isolation check on this Mac are marked, and the catalog says up front what a copy can't do."
            ),
        ]),
        Release(version: "0.12.0", highlights: [
            Highlight(
                symbol: "person.2",
                title: "Two WhatsApps, two accounts",
                detail: "Own copies of App Store apps now get their own shared containers too — where WhatsApp and others keep their sign-in and messages."
            ),
            Highlight(
                symbol: "macwindow",
                title: "One calm window",
                detail: "The sidebar, content and toolbar are a single frosted surface, with the Parallex wordmark up top."
            ),
        ]),
        Release(version: "0.11.0", highlights: [
            Highlight(
                symbol: "arrow.right.doc.on.clipboard",
                title: "Start from the original's data",
                detail: "Give a new copy the original app's settings, library and sign-ins, then let the two go their own ways."
            ),
            Highlight(
                symbol: "shippingbox",
                title: "Export and import",
                detail: "Save an instance, settings and data, as one .parallex file. Keep it as a backup, or open it on another Mac."
            ),
        ]),
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
