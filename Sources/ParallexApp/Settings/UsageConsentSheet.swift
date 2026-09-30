import ParallexCore
import SwiftUI

/// Asked once of people who used Parallex before sharing usage became the
/// default (new installs choose in onboarding): share, or don't. Either way
/// it can be changed in Settings › About.
struct UsageConsentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingReport = false

    private let shared = [
        "Which well-known apps you copy, and how those copies do",
        "What fails and where: a copy that quits at launch, a refresh or update that doesn't finish",
        "Which features you use, and Parallex's own crashes",
        "Parallex's version, macOS's version and your Mac's chip",
    ]
    private let never = [
        "Instance names, file names, paths or contents",
        "Apps that aren't well-known or from the App Store (only counted)",
        "Your IP address, which isn't stored",
        "Anything that ties it to you: it's under a random number, renewed every 180 days",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Help make Parallex better")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.3)
                Text("Parallex is free, and it changes every week. A daily anonymous report shows which releases and app updates break copies, often before anyone has to write in.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: Theme.Space.l) {
                column("What's shared", symbol: "checkmark", items: shared)
                column("What never is", symbol: "xmark", items: never)
            }
            HStack {
                Button("See What's Sent") { showingReport = true }
                    .buttonStyle(.plain)
                    .font(Theme.Font.callout.weight(.medium))
                    .foregroundStyle(Theme.accent)
                Spacer()
                Button("Don't Share") { choose(.declined) }
                    .quietAction()
                Button("Share") { choose(.shared) }
                    .prominentAction()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 600)
        .interactiveDismissDisabled()
        .sheet(isPresented: $showingReport) { UsagePreview() }
    }

    private func column(_ title: String, symbol: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold))
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(symbol == "checkmark" ? Theme.accent : .secondary)
                        .frame(width: 12)
                    Text(item)
                        .font(Theme.Font.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassSurface(cornerRadius: 14)
    }

    private func choose(_ consent: Telemetry.Consent) {
        Telemetry.setConsent(consent)
        dismiss()
    }
}
