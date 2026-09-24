import AppKit
import SwiftUI

/// Where people can chip in. Parallex is free; donations pay for its upkeep
/// and, first, for signing it with Apple (so it opens without "Open Anyway").
enum SupportLinks {
    static let sponsors = URL(string: "https://github.com/sponsors/mandipadk")!
    static let koFi = URL(string: "https://ko-fi.com/mandipadk")!
}

extension PreferenceKey {
    /// When this Mac first ran a Parallex that knows to ask.
    static let firstUsed = "firstUsed"
    /// The one-time "support Parallex" card was closed (or used).
    static let supportCardDone = "supportCardDone"
}

/// Asks once, after two weeks with Parallex, at the foot of the sidebar.
/// Closing it or following a link puts it away for good.
struct SupportCard: View {
    @AppStorage(PreferenceKey.supportCardDone) private var done = false
    @Environment(AppModel.self) private var model

    var body: some View {
        if !done, Self.isDue(entries: model.entries) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Enjoying Parallex?")
                        .font(Theme.Font.headline)
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(Theme.Motion.snappy) { done = true }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 18, height: 18)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Not now")
                }
                Text("It's free, and made by a student. A few dollars helps get it signed by Apple, so it opens without “Open Anyway”.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    // Not fixedSize: sizing the window, macOS measures the
                    // sidebar's bar at almost no width, and a fixed-height
                    // text there set the window's minimum to its full height.
                    .lineLimit(4)
                HStack(spacing: Theme.Space.s) {
                    Button("Sponsor") { open(SupportLinks.sponsors) }
                        .buttonStyle(.primary)
                    Button("Ko-fi") { open(SupportLinks.koFi) }
                        .buttonStyle(.secondary)
                }
                .controlSize(.small)
            }
            .padding(Theme.Space.m)
            .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.tile))
            .padding(.horizontal, Theme.Space.m)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
        withAnimation(Theme.Motion.snappy) { done = true }
    }

    /// Two weeks after Parallex first ran here, or after the oldest instance
    /// was made (for people who had it before it knew to ask), with at
    /// least one instance to show for it.
    static func isDue(entries: [InstanceEntry], now: Date = Date()) -> Bool {
        #if DEBUG
        if DebugRoute.value == "support" { return true }
        #endif
        guard !entries.isEmpty else { return false }
        let firstUsed = UserDefaults.standard.object(forKey: PreferenceKey.firstUsed) as? Date ?? now
        let start = min(firstUsed, entries.map(\.manifest.createdAt).min() ?? now)
        return now.timeIntervalSince(start) >= 14 * 24 * 60 * 60
    }
}
