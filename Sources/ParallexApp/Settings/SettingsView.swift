import AppKit
import ParallexCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            LinksSettings()
                .tabItem { Label("Sign-in Links", systemImage: "link") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 540)
        .tint(Theme.accent)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage(PreferenceKey.tagWindows) private var tagWindows = true
    @AppStorage(PreferenceKey.tagShowsName) private var tagShowsName = true
    @AppStorage(PreferenceKey.switcherHotKey) private var switcherHotKey = true
    @AppStorage(PreferenceKey.autoMaintain) private var autoMaintain = true
    @AppStorage(PreferenceKey.onboardingCompleted) private var onboardingCompleted = true
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                Toggle("Open Parallex at login", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: setOpenAtLogin
                ))
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("Allow Parallex in Login Items to finish turning this on.")
                            .font(Theme.Font.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginError {
                    Text(loginError).font(Theme.Font.callout).foregroundStyle(Theme.failure)
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("Parallex runs from the menu bar. At login it opens without a window, keeps sign-in links and outlines working, and opens instances set to open with it.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle("Keep instances up to date", isOn: $autoMaintain)
            } header: {
                Text("Maintenance")
            } footer: {
                Text("When Parallex updates, an app moves, or an app with an own-identity copy updates, Parallex rebuilds the affected instances while they're not running. Their data is never touched.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle("Outline instance windows in their color", isOn: $tagWindows)
                Toggle("Show the instance name on the outline", isOn: $tagShowsName)
                    .disabled(!tagWindows)
                Toggle("⌃⌥Space opens the switcher", isOn: $switcherHotKey)
            } header: {
                Text("Telling instances apart")
            } footer: {
                Text("Unless an instance has its own identity, macOS shows it under the original app's name and icon. Outlines, the menu bar, and the switcher make the difference visible. If “Select next source in Input menu” uses ⌃⌥Space, it takes precedence.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                HStack {
                    Text("Walk through the introduction and setup again.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Welcome") {
                        onboardingCompleted = false
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate()
                        openWindow(id: SceneID.main)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: tagWindows) { notify() }
        .onChange(of: tagShowsName) { notify() }
        .onChange(of: switcherHotKey) { notify() }
        .onAppear { loginStatus = SMAppService.mainApp.status }
    }

    private func notify() {
        NotificationCenter.default.post(name: .parallexPreferencesChanged, object: nil)
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        loginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginError = error.localizedDescription
        }
        loginStatus = SMAppService.mainApp.status
    }
}

// MARK: - Sign-in links

private struct LinksSettings: View {
    @State private var config = LinkRouting.loadConfiguration()
    @State private var schemes: [SchemeRow] = []
    @State private var working = false
    @State private var errorMessage: String?

    struct SchemeRow: Identifiable {
        let scheme: String
        let app: String
        let routed: Bool
        var id: String { scheme }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Send sign-in links to the right copy", isOn: Binding(
                    get: { config.enabled },
                    set: setEnabled
                ))
                .disabled(working || (schemes.isEmpty && !config.enabled))
                if config.enabled {
                    Toggle("Ask which copy to use when several are open", isOn: Binding(
                        get: { config.alwaysAsk },
                        set: { ask in
                            try? LinkRouting.setAlwaysAsk(ask)
                            reload()
                        }
                    ))
                }
            } footer: {
                Text("Apps finish signing in by opening a link like claude://…. With several copies open, macOS picks one at random. Parallex passes the link to the copy you used last. macOS may ask you to confirm the change, and to let Parallex Links control the app the first time.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !schemes.isEmpty {
                Section("Links handled") {
                    ForEach(schemes) { row in
                        HStack(spacing: Theme.Space.m) {
                            AppIcon(path: row.app, size: 18)
                            Text("\(row.scheme)://")
                                .font(Theme.Font.mono)
                            Spacer()
                            if config.enabled {
                                StatusPill(state: row.routed ? .running : .attention("Not routed"))
                            }
                        }
                    }
                    if config.enabled, schemes.contains(where: { !$0.routed }) {
                        HStack {
                            Text("Apps take their links back when they start; Parallex reclaims them while it's running.")
                                .font(Theme.Font.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Route Now") { setEnabled(true) }.disabled(working)
                        }
                    }
                }
            } else {
                Section {
                    Text("None of your instances' apps use custom sign-in links.")
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(Theme.failure)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
    }

    private func reload() {
        config = LinkRouting.loadConfiguration()
        schemes = LinkRouting.routableSchemes(InstanceStore.loadAll())
            .sorted { $0.key < $1.key }
            .map { SchemeRow(scheme: $0.key, app: $0.value, routed: LinkRouting.isRouting($0.key)) }
    }

    private func setEnabled(_ enabled: Bool) {
        working = true
        errorMessage = nil
        Task {
            do {
                if enabled {
                    _ = try await LinkRouting.enable(
                        routerBinary: try LauncherLocator.locateRouter(), manifests: InstanceStore.loadAll()
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

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: Theme.Space.l) {
            ParallelMark(size: 72, split: 1)
                .padding(.top, Theme.Space.xl)
            VStack(spacing: 4) {
                Text("Parallex").font(Theme.Font.title)
                Text("Version \(ParallexConfigVersion.current)")
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text("Every app, as many times as you need.")
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
            HStack(spacing: Theme.Space.s) {
                Link(destination: URL(string: "https://github.com/mandipadk/parallex")!) {
                    Text("Source on GitHub")
                }
                .buttonStyle(.secondary)
            }
            Text("Free and open source under the MIT License.")
                .font(Theme.Font.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, Theme.Space.xl)
        }
        .frame(maxWidth: .infinity)
    }
}
