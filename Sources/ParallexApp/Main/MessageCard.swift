import AppKit
import ParallexCore
import SwiftUI

extension PreferenceKey {
    /// Notices' messages already read and closed.
    static let closedMessages = "closedNoticeMessages"
}

/// A message from Parallex's maintainer (signed; see `Advisories`) for this
/// version, at the foot of the sidebar until it's closed; otherwise the
/// one-time support card.
struct MessageCard: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PreferenceKey.closedMessages) private var closedRaw = ""

    private var closed: Set<String> { Set(closedRaw.split(separator: "\n").map(String.init)) }

    private var message: Advisories.Message? {
        model.advisories?.messages().first { !closed.contains($0.id) }
    }

    var body: some View {
        if let message {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.title).font(Theme.Font.headline)
                    Spacer(minLength: 0)
                    Button {
                        close(message)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 18, height: 18)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                // Capped, never fixed-height: the sidebar's bar is measured
                // at almost no width when the window's size is worked out.
                Text(message.body)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                if let link = message.link.flatMap(URL.init(string:)), link.scheme == "https" {
                    Button("Learn More") {
                        NSWorkspace.shared.open(link)
                        close(message)
                    }
                    .buttonStyle(.secondary)
                    .controlSize(.small)
                }
            }
            .padding(Theme.Space.m)
            .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.tile))
            .padding(.horizontal, Theme.Space.m)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else {
            SupportCard()
        }
    }

    private func close(_ message: Advisories.Message) {
        withAnimation(Theme.Motion.snappy) {
            closedRaw = (closed.union([message.id])).sorted().joined(separator: "\n")
        }
    }
}
