import ParallexCore
import SwiftUI

/// What a web link can be sent to on this Mac: your usual browser, a
/// browser, one profile of a Chromium browser, or a browser instance.
struct WebLinkChoices {
    struct Choice: Identifiable, Hashable {
        let target: WebLinkTarget?
        let title: String
        let icon: String?
        var id: String { title + (icon ?? "") }
    }

    var browsers: [Choice] = []
    var profiles: [Choice] = []
    var instances: [Choice] = []

    @MainActor
    static func load(entries: [InstanceEntry]) -> WebLinkChoices {
        let browsers = WebRouting.browsers()
        let browserIDs = Set(browsers.map(\.bundleID))
        return WebLinkChoices(
            browsers: browsers.map { Choice(target: .browser(path: $0.url.path), title: $0.name, icon: $0.url.path) },
            profiles: WebRouting.profiles(in: browsers).map {
                Choice(target: $0.target, title: "\($0.browserName) — \($0.name)", icon: $0.browser.path)
            },
            // Instances of browsers: a copy or wrapper of Chrome, Brave, …
            instances: entries
                .filter { browserIDs.contains($0.manifest.knownTargetBundleID ?? "") }
                .map { Choice(target: .instance(slug: $0.id), title: $0.name, icon: $0.iconPath) }
        )
    }

    func title(for target: WebLinkTarget?) -> String {
        guard let target else { return "Your usual browser" }
        return (browsers + profiles + instances).first { $0.target == target }?.title
            ?? WebRouting.describe(target, manifests: [])
    }
}

/// A menu for where web links go.
struct WebLinkTargetPicker: View {
    @Binding var target: WebLinkTarget?
    let choices: WebLinkChoices
    /// Shown instead of "Your usual browser" when nothing's chosen yet, and
    /// that option is left out (a site rule needs somewhere to go).
    var placeholder: String?

    var body: some View {
        Menu {
            if placeholder == nil {
                Button("Your usual browser") { target = nil }
            }
            section("Browsers", choices.browsers)
            section("Profiles", choices.profiles)
            section("Instances", choices.instances)
        } label: {
            Text(target == nil ? placeholder ?? choices.title(for: nil) : choices.title(for: target))
                .lineLimit(1)
        }
        .menuStyle(.button)
        .fixedSize()
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [WebLinkChoices.Choice]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { choice in
                    Button(choice.title) { target = choice.target }
                }
            }
        }
    }
}
