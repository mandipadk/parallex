import AppKit
import ParallexCore
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
        Release(version: "1.9.2", highlights: [
            Highlight(
                symbol: "exclamationmark.shield",
                title: "No second Arc, for now",
                detail: "Arc keeps using its own profile in an instance, so Parallex no longer makes new Arc instances until a second Arc can be kept apart."
            ),
        ]),
        Release(version: "1.9.1", highlights: [
            Highlight(
                symbol: "person.2.wave.2",
                title: "Two Microsoft Teams",
                detail: "Copies of Teams now open and sign in to another account. Its web view used to refuse the copy's own signature and close right away."
            ),
            Highlight(
                symbol: "rectangle.dashed",
                title: "Outlines keep up",
                detail: "A window's colored outline now follows it as you drag or resize it, and is never left broken after a resize."
            ),
        ]),
        Release(version: "1.9.0", highlights: [
            Highlight(
                symbol: "plus.square.on.square",
                title: "Another one of that",
                detail: "The menu bar now offers Another <app>… for the app or website you were last in, and opens New Instance with it already picked."
            ),
            Highlight(
                symbol: "sparkles.rectangle.stack",
                title: "Open in a Clean Window",
                detail: "Select a web address in any app, then Services › Open in a Clean Window: it opens in a window with none of your cookies or sign-ins, and everything it kept goes to the Trash when you close it."
            ),
        ]),
        Release(version: "1.8.1", highlights: [
            Highlight(
                symbol: "exclamationmark.bubble",
                title: "Something's off with this one",
                detail: "An instance's ⋯ menu, and its right-click menu in the sidebar, now have Something's Off…, with that instance already picked."
            ),
            Highlight(
                symbol: "person.2.badge.key",
                title: "The right GitHub account, every push",
                detail: "In a workspace with its own identity, git now uses the GitHub account the workspace's gh is signed in to, so two workspaces with two accounts each find their own sign-in in the keychain."
            ),
        ]),
        Release(version: "1.8.0", highlights: [
            Highlight(
                symbol: "exclamationmark.bubble",
                title: "Something's off? Say so",
                detail: "Something's Off… in the menu bar, the Help menu and Settings sends a note, in your words, straight to Parallex's maker, with a few facts about the instance it's about. See What's Sent shows every word first."
            ),
            Highlight(
                symbol: "megaphone",
                title: "Heads-ups sooner",
                detail: "When an app update breaks copies, a notice can now reach Parallex within hours of it showing up, before a fix does."
            ),
            Highlight(
                symbol: "paperplane",
                title: "Telegram copies work",
                detail: "Copies of Telegram no longer close a few seconds after they open. Existing ones are rebuilt for you when they're not running."
            ),
        ]),
        Release(version: "1.7.0", highlights: [
            Highlight(
                symbol: "list.bullet.rectangle",
                title: "Everything you missed",
                detail: "Updating past a few releases at once now shows what came in each of them, here and in the update window, not just the newest."
            ),
            Highlight(
                symbol: "shield.lefthalf.filled",
                title: "Releases that can stop themselves",
                detail: "Parallex's server can now send a new release to a few Macs first, then more each day it stays healthy, and stop it on its own if it starts crashing or breaking copies."
            ),
            Highlight(
                symbol: "gearshape",
                title: "Settings comes forward",
                detail: "Settings… in the menu bar now opens Settings in front of your other windows."
            ),
        ]),
        Release(version: "1.6.0", highlights: [
            Highlight(
                symbol: "chart.bar.xaxis",
                title: "A daily report, if you'll share it",
                detail: "Parallex can now tell its server, once a day, which well-known apps you copy and how they do, what fails and where, and its own crashes, under a random number renewed every 180 days. Never names, paths or contents. It asks first; See What's Sent shows every word."
            ),
            Highlight(
                symbol: "stethoscope",
                title: "Broken releases caught sooner",
                detail: "Each release is now judged against the one before it on crashes, updates, refreshes and copies quitting at launch, so a bad one can be paused before it reaches everyone."
            ),
        ]),
        Release(version: "1.5.0", highlights: [
            Highlight(
                symbol: "slider.horizontal.3",
                title: "Settings, not accounts",
                detail: "An editor copy (VS Code, Cursor, Zed, …) can use the original's settings, keybindings, snippets and extensions, kept in step, while its sign-ins and projects stay its own. Share settings in its Isolation section."
            ),
            Highlight(
                symbol: "stethoscope",
                title: "Every instance at a glance",
                detail: "parallex health shows each instance's app version, how its isolation has held, what Guard kept out, its snapshots, and anything that needs doing."
            ),
        ]),
        Release(version: "1.4.0", highlights: [
            Highlight(
                symbol: "person.2.badge.key",
                title: "Who you are, at a glance",
                detail: "A workspace with its own identity shows who git, GitHub, AWS, Kubernetes, Google Cloud and npm think you are there, beside who they think you are everywhere else."
            ),
            Highlight(
                symbol: "network",
                title: "A network per workspace",
                detail: "Give a workspace a proxy, a client's or a tunnel of your own: its apps and what they start go through it, and nothing else does. Network on the workspace's page."
            ),
            Highlight(
                symbol: "calendar.badge.clock",
                title: "Daily snapshots",
                detail: "Turn on Take one every day in an instance's Snapshots, and it keeps a week of days to go back to, taken while it isn't running."
            ),
        ]),
        Release(version: "1.3.0", highlights: [
            Highlight(
                symbol: "arrow.uturn.backward.circle",
                title: "Go back a version",
                detail: "A copy keeps the version of its app it was on. If an update gets in the way, go back to it, and stay there while the app moves on. From Versions on the instance's page."
            ),
            Highlight(
                symbol: "person.crop.rectangle.stack",
                title: "Workspaces as identities",
                detail: "Give a workspace its own git, gh, cloud and cluster identity. Terminal and editor copies in it, and parallex run, work as that workspace, while yours stays yours. Identity on the workspace's page."
            ),
            Highlight(
                symbol: "clock.arrow.circlepath",
                title: "With its data as it was",
                detail: "Before a copy moves to another version, Parallex takes a snapshot of its data, so going back can take the data back too, as that version left it."
            ),
        ]),
        Release(version: "1.2.0", highlights: [
            Highlight(
                symbol: "shield.lefthalf.filled",
                title: "Guard, and a record to prove it",
                detail: "A copy with its own Library can't open the original's data, even by its full path, and keeps a record of every file of yours it touches. Verify Isolation now covers a copy's whole life, running or not."
            ),
            Highlight(
                symbol: "clock.arrow.circlepath",
                title: "Snapshots",
                detail: "Keep an instance's data and sign-ins as they are, and go back in a moment if something goes wrong. Taking one is instant, and a restore can be undone the same way."
            ),
            Highlight(
                symbol: "arrow.uturn.backward",
                title: "Sign-ins land in the right copy",
                detail: "With Parallex Links on, a sign-in started in one copy finishes in that copy, whatever you switched to meanwhile. And when a copy writes to a folder you share, Isolation offers to keep it to that copy."
            ),
        ]),
        Release(version: "1.1.0", highlights: [
            Highlight(
                symbol: "hand.raised",
                title: "Copies keep your permissions",
                detail: "Camera, microphone, screen recording and folder access you give a copy now stay when its app updates. Copies made before ask once more after their next refresh."
            ),
            Highlight(
                symbol: "key",
                title: "A keychain of their own",
                detail: "New copies keep their sign-ins in their own keychain, so they never find or replace the original's, and keep them through updates. For older copies, turn on Separate keychain in Isolation."
            ),
            Highlight(
                symbol: "arrow.triangle.2.circlepath",
                title: "Always up to date, even while in use",
                detail: "When an app updates, its copy is refreshed in the background and takes over the moment you quit it. The app's own updater stays off in copies, so it can never turn one back into the original."
            ),
        ]),
        Release(version: "1.0.0", highlights: [
            Highlight(
                symbol: "sparkles",
                title: "Parallex 1.0",
                detail: "Copies with their own identity, workspaces, link routing, websites as apps, throwaways, Shortcuts and Focus: all of it, tested and steady. Thank you for using it."
            ),
            Highlight(
                symbol: "book",
                title: "How Parallex works, in plain words",
                detail: "What Parallex does to an app to run it twice, including the trade-offs: parallex.mandip.dev/how-it-works, also in Settings › About."
            ),
            Highlight(
                symbol: "shippingbox",
                title: "Install with Homebrew",
                detail: "brew install --cask parallex, after brew tap mandipadk/parallex https://github.com/mandipadk/parallex. VoiceOver also reads Parallex better now."
            ),
        ]),
        Release(version: "0.22.0", highlights: [
            Highlight(
                symbol: "checklist",
                title: "How apps work for others",
                detail: "parallex.mandip.dev/compatibility lists how apps do as instances, from people's reports and anonymous usage. It's linked from New Instance."
            ),
            Highlight(
                symbol: "exclamationmark.bubble",
                title: "Heads-ups from Parallex",
                detail: "When an app update breaks copies, Parallex can say so where you make or open an instance of it, and suggest its website instead. The notices are signed, so only Parallex can send them."
            ),
        ]),
        Release(version: "0.21.0", highlights: [
            Highlight(
                symbol: "chart.bar.xaxis",
                title: "Help spot broken apps early",
                detail: "Turn on Share anonymous usage in Settings › About and Parallex tells its server which apps you copy and how those copies do, once a week. See What's Sent shows every word first. Off unless you turn it on."
            ),
            Highlight(
                symbol: "arrow.triangle.2.circlepath",
                title: "Safer updates",
                detail: "New versions can reach a few Macs first, and a bad one can be pulled before most people get it."
            ),
        ]),
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

    /// Every release after `lastSeen`, up to this one, newest first: what
    /// someone who skipped a few hasn't seen. Just this one without
    /// `lastSeen` (or when nothing in between has highlights).
    static func since(_ lastSeen: String?) -> [Release] {
        let current = ParallexConfig.version
        guard let lastSeen else { return self.current.map { [$0] } ?? [] }
        let missed = releases.filter {
            UpdateFeed.isNewer($0.version, than: lastSeen) && !UpdateFeed.isNewer($0.version, than: current)
        }
        return missed.isEmpty ? (self.current.map { [$0] } ?? []) : missed
    }
}

/// Shown once after Parallex updates (with every release since the one
/// last seen), and from Settings › About.
struct WhatsNewView: View {
    var releases: [ReleaseHighlights.Release] = ReleaseHighlights.current.map { [$0] } ?? []
    var onContinue: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var subtitle: String {
        guard releases.count > 1, let newest = releases.first, let oldest = releases.last else {
            return "Version \(releases.first?.version ?? ParallexConfig.version)"
        }
        return "Everything from \(oldest.version) to \(newest.version)"
    }

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
                    Text(subtitle)
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .opacity(appeared ? 1 : 0)
            }
            .padding(.top, Theme.Space.xxl)
            .padding(.bottom, Theme.Space.xl)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    ForEach(Array(releases.enumerated()), id: \.element.version) { index, release in
                        VStack(alignment: .leading, spacing: Theme.Space.l) {
                            if releases.count > 1 {
                                Text("Parallex \(release.version)")
                                    .font(Theme.Font.callout.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            ForEach(release.highlights) { item in
                                HighlightRow(item: item)
                            }
                        }
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared || reduceMotion ? 0 : 10)
                        .animation(
                            reduceMotion ? Theme.Motion.fade : Theme.Motion.smooth.delay(0.12 + Double(min(index, 4)) * 0.06),
                            value: appeared
                        )
                    }
                }
                .padding(.horizontal, Theme.Space.xxl + Theme.Space.s)
                .padding(.top, Theme.Space.xs)
                .padding(.bottom, Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)

            Button("Continue", action: onContinue)
                .keyboardShortcut(.defaultAction)
                .prominentAction()
                .padding(.vertical, Theme.Space.xl)
        }
        .frame(width: 500, height: releases.count > 1 ? 620 : 560)
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
