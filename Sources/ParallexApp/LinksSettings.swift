import SwiftUI
import ParallexCore

/// Settings section for sign-in link routing (see `LinkRouting`).
struct LinksSettings: View {
    @State private var config = LinkRouting.loadConfiguration()
    @State private var schemes: [(scheme: String, app: String, routed: Bool)] = []
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Toggle("Send sign-in links to the right instance", isOn: Binding(
                get: { config.enabled },
                set: { setEnabled($0) }
            ))
            .disabled(working || (schemes.isEmpty && !config.enabled))
            if config.enabled {
                Toggle("Ask which copy to use when several are running", isOn: Binding(
                    get: { config.alwaysAsk },
                    set: { ask in
                        try? LinkRouting.setAlwaysAsk(ask)
                        reload()
                    }
                ))
            }
            ForEach(schemes, id: \.scheme) { item in
                HStack {
                    Text("\(item.scheme)://").font(.system(.body, design: .monospaced))
                    Text(URL(fileURLWithPath: item.app).deletingPathExtension().lastPathComponent)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if config.enabled {
                        Text(item.routed ? "routed" : "not routed")
                            .font(.caption)
                            .foregroundStyle(item.routed ? Color.green : Color.orange)
                    }
                }
            }
            if config.enabled, schemes.contains(where: { !$0.routed }) {
                Button("Route New Schemes") { setEnabled(true) }
                    .disabled(working)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Sign-in links")
        } footer: {
            Text(schemes.isEmpty
                 ? "None of your instances' apps use custom link schemes."
                 : "Apps finish sign-in by opening a link (claude://…). With several copies running, macOS picks one at random; Parallex passes the link to the copy you used last. macOS may ask you to confirm the change, and to let Parallex Links control the app the first time.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        config = LinkRouting.loadConfiguration()
        schemes = LinkRouting.routableSchemes(InstanceStore.loadAll())
            .sorted { $0.key < $1.key }
            .map { (scheme: $0.key, app: $0.value, routed: LinkRouting.isRouting($0.key)) }
    }

    private func setEnabled(_ enabled: Bool) {
        working = true
        errorMessage = nil
        Task {
            do {
                if enabled {
                    _ = try await LinkRouting.enable(
                        routerBinary: try LauncherLocator.locateRouter(),
                        manifests: InstanceStore.loadAll()
                    )
                } else {
                    try await LinkRouting.disable()
                }
            } catch {
                errorMessage = "\(error)"
            }
            working = false
            reload()
        }
    }
}
