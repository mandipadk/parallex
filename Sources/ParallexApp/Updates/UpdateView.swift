import AppKit
import ParallexCore
import ParallexKit
import SwiftUI

/// The Software Update window: checking, what's in the new version, and the
/// download and install.
struct UpdateView: View {
    /// Closes the window (it's hosted in an AppKit window, where SwiftUI's
    /// dismiss action does nothing).
    var close: () -> Void
    @Environment(Updater.self) private var updater

    var body: some View {
        Group {
            switch updater.phase {
            case .checking:
                StatusMessage(symbol: nil, title: "Checking for updates…", detail: nil) {
                    Button("Cancel", action: close).quietAction()
                }
            case .idle:
                StatusMessage(
                    symbol: "arrow.down.circle",
                    title: "Software Update",
                    detail: "You have Parallex \(ParallexConfig.version)."
                ) {
                    HStack(spacing: Theme.Space.s) {
                        Button("Close", action: close).quietAction()
                        Button("Check Now") { updater.check(userInitiated: true) }
                            .keyboardShortcut(.defaultAction)
                            .prominentAction()
                    }
                }
            case .upToDate:
                StatusMessage(
                    symbol: "checkmark.circle.fill",
                    title: "Parallex is up to date",
                    detail: "Version \(ParallexConfig.version) is the newest."
                ) {
                    Button("OK") { updater.dismiss(); close() }
                        .keyboardShortcut(.defaultAction)
                        .prominentAction()
                }
            case .failed(let message):
                StatusMessage(symbol: "exclamationmark.triangle.fill", title: "Couldn't update", detail: message) {
                    HStack(spacing: Theme.Space.s) {
                        Button("Close") { updater.dismiss(); close() }.quietAction()
                        Button("Try Again") { updater.check(userInitiated: true) }
                            .keyboardShortcut(.defaultAction)
                            .prominentAction()
                    }
                }
            case .available(let release):
                ReleaseView(release: release, progress: nil, installing: false, close: close)
            case .downloading(let release, let progress):
                ReleaseView(release: release, progress: progress, installing: false, close: close)
            case .installing(let release):
                ReleaseView(release: release, progress: 1, installing: true, close: close)
            }
        }
        .frame(width: 540, height: 460)
        .background(WindowGlassBackground().ignoresSafeArea())
        .tint(Theme.accent)
        .animation(Theme.Motion.smooth, value: updater.phase)
    }
}

private func symbolColor(_ symbol: String) -> Color {
    if symbol.hasPrefix("checkmark") { return Theme.running }
    if symbol.hasPrefix("exclamationmark") { return Theme.attention }
    return Theme.accent
}

private struct StatusMessage<Actions: View>: View {
    let symbol: String?
    let title: String
    let detail: String?
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 34))
                        .foregroundStyle(symbolColor(symbol))
                        .symbolRenderingMode(.hierarchical)
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(height: 40)
            VStack(spacing: 6) {
                Text(title).font(Theme.Font.title)
                if let detail {
                    Text(detail)
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 380)
                }
            }
            Spacer()
            actions.padding(.bottom, Theme.Space.xl)
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }
}

private struct ReleaseView: View {
    let release: ReleaseInfo
    let progress: Double?
    let installing: Bool
    let close: () -> Void
    @Environment(Updater.self) private var updater

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.m + 2) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Parallex \(release.version) is available")
                        .font(Theme.Font.title)
                    Text("You have \(ParallexConfig.version). Your instances and their data stay as they are.")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.xl)
            .padding(.bottom, Theme.Space.l)

            ScrollView {
                ReleaseNotes(markdown: release.notes)
                    .padding(Theme.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: Theme.Radius.tile))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile).strokeBorder(Theme.hairline))
            .padding(.horizontal, Theme.Space.xl)

            footer
                .padding(.horizontal, Theme.Space.xl)
                .padding(.vertical, Theme.Space.l)
        }
    }

    @ViewBuilder private var footer: some View {
        if let progress {
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(installing ? "Installing — Parallex will reopen in a moment" : "Downloading…")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                    ProgressView(value: installing ? nil : progress)
                        .progressViewStyle(.linear)
                }
                if !installing {
                    Button("Cancel") { updater.cancelDownload() }.quietAction()
                }
            }
        } else {
            HStack(spacing: Theme.Space.s) {
                Button("Skip This Version") {
                    updater.skip(release)
                    close()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Later", action: close).quietAction()
                Button(updater.canInstallInPlace ? "Update" : "Download") { updater.install(release) }
                    .keyboardShortcut(.defaultAction)
                    .prominentAction()
            }
        }
    }
}

/// Release notes in the small Markdown subset they're written in: headings,
/// bullet lists and paragraphs, with inline emphasis, code and links.
struct ReleaseNotes: View {
    let markdown: String

    enum Block: Hashable {
        case heading(String)
        case bullet(String)
        case paragraph(String)
    }

    static func blocks(from markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                blocks.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    var body: some View {
        let blocks = Self.blocks(from: markdown)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if blocks.isEmpty {
                Text("Bug fixes and improvements.").foregroundStyle(.secondary)
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(inline(text))
                        .font(Theme.Font.headline)
                        .padding(.top, Theme.Space.xs)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Circle().fill(.secondary).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                        Text(inline(text)).fixedSize(horizontal: false, vertical: true)
                    }
                case .paragraph(let text):
                    Text(inline(text)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(Theme.Font.body)
        .textSelection(.enabled)
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
