import AppKit
import ParallexCore
import ParallexKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @State private var tab = Self.initialTab

    private static var initialTab: String {
        #if DEBUG
        DebugRoute.settingsTab ?? "general"
        #else
        "general"
        #endif
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            LinksSettings()
                .tabItem { Label("Links", systemImage: "link") }
                .tag("links")
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag("about")
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
    @AppStorage(PreferenceKey.autoVerify) private var autoVerify = true
    @AppStorage(PreferenceKey.onboardingCompleted) private var onboardingCompleted = true
    @AppStorage(PreferenceKey.notifyProblems) private var notifyProblems = true
    @AppStorage(PreferenceKey.notifyUpdates) private var notifyUpdates = true
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                Toggle("Open Parallex at login", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: { setOpenAtLogin($0) }
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
                Toggle("Check isolation while instances run", isOn: $autoVerify)
            } header: {
                Text("Maintenance")
            } footer: {
                Text("When Parallex updates, an app moves, or an app with an own-identity copy updates, Parallex rebuilds the affected instances while they're not running. Their data is never touched. Shortly after an instance opens, Parallex also checks the files it has open and tells you if it's using the original app's data.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle("When an instance needs attention", isOn: $notifyProblems)
                Toggle("When a Parallex update is available", isOn: $notifyUpdates)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Parallex only speaks up for a copy that's behind its app, an app that went missing, or a repair that didn't work — each once, with the fix one click away.")
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
    @State private var linkChoices = WebLinkChoices()
    @State private var newSite = ""
    @State private var newSiteTarget: WebLinkTarget?
    @State private var webIsDefault = true
    @Environment(AppModel.self) private var model

    struct SchemeRow: Identifiable {
        let scheme: String
        let app: String
        let routed: Bool
        var id: String { scheme }
    }

    var body: some View {
        Form {
            webSection

            if config.routesWeb {
                sitesSection
            }

            Section {
                Toggle("Send sign-in links to the right copy", isOn: Binding(
                    get: { config.enabled },
                    set: { setEnabled($0) }
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
        .onAppear {
            reload()
            linkChoices = .load(entries: model.entries)
        }
    }

    private var webSection: some View {
        Section {
            Toggle("Open web links in the right browser", isOn: Binding(
                get: { config.routesWeb },
                set: { setWeb($0) }
            ))
            .disabled(working)
            if config.routesWeb, !webIsDefault {
                HStack {
                    Text("Another browser has made itself the default, so links aren't routed right now.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.attention)
                    Spacer()
                    Button("Route Again") { setWeb(true) }.disabled(working)
                }
            }
        } footer: {
            Text(webFooter)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var webFooter: String {
        let usual = config.previousBrowser.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        let rest = usual.map { "everything else opens in \($0), as before" } ?? "everything else opens in your usual browser"
        return "Links you click in an instance open in its workspace's browser, sites below open where you say, and "
            + "\(rest). Parallex Links becomes your default browser; macOS asks you to confirm."
    }

    private var sitesSection: some View {
        Section("Always open these sites in…") {
            ForEach(config.webRules ?? [], id: \.domain) { rule in
                HStack(spacing: Theme.Space.m) {
                    Text(rule.domain).font(Theme.Font.mono)
                    Spacer()
                    WebLinkTargetPicker(
                        target: Binding(get: { rule.target }, set: { target in setRule(rule.domain, target) }),
                        choices: linkChoices
                    )
                    Button {
                        setRule(rule.domain, nil)
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove the rule for \(rule.domain)")
                }
            }
            HStack(spacing: Theme.Space.m) {
                TextField("Site", text: $newSite, prompt: Text("Add a site, like northwind.com"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addSite)
                WebLinkTargetPicker(target: $newSiteTarget, choices: linkChoices, placeholder: "Open in…")
                Button("Add", action: addSite)
                    .disabled(WebRouting.normalizedDomain(newSite).isEmpty || newSiteTarget == nil)
            }
        }
    }

    private func addSite() {
        let domain = WebRouting.normalizedDomain(newSite)
        guard domain.contains("."), let target = newSiteTarget else { return }
        setRule(domain, target)
        newSite = ""
        newSiteTarget = nil
    }

    /// Add, change (target) or remove (nil) a site rule.
    private func setRule(_ domain: String, _ target: WebLinkTarget?) {
        var rules = (config.webRules ?? []).filter { WebRouting.normalizedDomain($0.domain) != domain }
        if let target {
            rules.append(WebLinkRule(domain: domain, target: target))
        }
        do {
            try LinkRouting.setWebRules(rules.sorted { $0.domain < $1.domain })
        } catch {
            errorMessage = "\(error)"
        }
        reload()
    }

    private func setWeb(_ on: Bool) {
        working = true
        errorMessage = nil
        Task {
            do {
                let router = try LauncherLocator.locateRouter()
                if on {
                    _ = try await LinkRouting.enableWeb(routerBinary: router)
                } else {
                    try await LinkRouting.disableWeb(routerBinary: router)
                }
            } catch {
                errorMessage = "\(error)"
            }
            working = false
            reload()
        }
    }

    private func reload() {
        config = LinkRouting.loadConfiguration()
        webIsDefault = WebRouting.schemes.allSatisfy(LinkRouting.isRouting)
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
    @Environment(Updater.self) private var updater
    @AppStorage(PreferenceKey.shareUsage) private var shareUsage = false
    @State private var showingUsage = false
    @Environment(\.showWhatsNew) private var showWhatsNew
    @Environment(\.checkForUpdates) private var checkForUpdates
    @State private var tool = CommandLineTool.status()
    @State private var toolError: String?

    var body: some View {
        @Bindable var updater = updater
        Form {
            Section {
                HStack(spacing: Theme.Space.l) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Parallex").font(Theme.Font.title)
                        Text("Version \(ParallexConfig.version)")
                            .font(Theme.Font.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    Button("What's New") { showWhatsNew() }
                }
                .padding(.vertical, Theme.Space.xs)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(updateStatus)
                        if let lastChecked = updater.lastChecked {
                            Text("Last checked \(lastChecked.formatted(.relative(presentation: .named)))")
                                .font(Theme.Font.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(updater.available == nil ? "Check Now" : "Update…") { checkForUpdates() }
                        .disabled(updater.phase == .checking)
                }
                Toggle("Check for updates automatically", isOn: $updater.automaticChecks)
            } header: {
                Text("Updates")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Parallex looks for a new version once a day. Updates are verified against Parallex's signing key before they're installed.")
                    Text("The check goes to parallex.mandip.dev and says only which Parallex, macOS and chip this is, whether it's the first check today, this week or this month, and a random number from 0 to 99 for staged releases. Active Macs can be counted, but nothing identifies you or this Mac.")
                    Link("What leaves your Mac", destination: URL(string: "https://parallex.mandip.dev/privacy")!)
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if tool != .notBundled {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(toolTitle)
                            Text(toolDetail)
                                .font(Theme.Font.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        if case .linked = tool {
                            EmptyView()
                        } else {
                            Button(toolButton, action: installTool)
                        }
                    }
                    if let toolError {
                        Text(toolError).font(Theme.Font.callout).foregroundStyle(Theme.failure)
                    }
                } header: {
                    Text("Command line")
                } footer: {
                    Text("Create, list and open instances from Terminal and scripts. The command stays in step with the app when it updates.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section {
                // Sent with the next daily update check, not the moment it's
                // turned on, so there's time to look at it first.
                Toggle("Share anonymous usage", isOn: $shareUsage)
                HStack {
                    Text("Which apps you copy and how those copies do, and which features you use. It helps spot an app update that breaks copies before the bug reports come in.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Theme.Space.l)
                    Button("See What's Sent") { showingUsage = true }
                }
            } header: {
                Text("Help improve Parallex")
            } footer: {
                Text("Off unless you turn it on. Once a week, with the next update check. No instance names, paths or identifier; apps are named only if they're well-known or from the App Store.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Support Parallex")
                        Text("Parallex is free and made by a student. Donations pay for its upkeep and, first, for signing it with Apple, so it opens without “Open Anyway”.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Theme.Space.l)
                    Button("GitHub Sponsors") { NSWorkspace.shared.open(SupportLinks.sponsors) }
                    Button("Ko-fi") { NSWorkspace.shared.open(SupportLinks.koFi) }
                }
                HStack {
                    Text("Free and open source under the MIT License.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link("How It Works", destination: URL(string: "https://parallex.mandip.dev/how-it-works")!)
                    Link("GitHub", destination: URL(string: "https://github.com/mandipadk/parallex")!)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { tool = CommandLineTool.status() }
        .sheet(isPresented: $showingUsage) { UsagePreview() }
    }

    private var updateStatus: String {
        switch updater.phase {
        case .checking: "Checking…"
        case .available(let release), .downloading(let release, _), .installing(let release):
            "Parallex \(release.version) is available"
        case .failed: "The last check didn't finish"
        default: "Parallex is up to date"
        }
    }

    private var toolTitle: String {
        switch tool {
        case .linked: "The parallex command is installed"
        case .separate: "Another copy of the parallex command is installed"
        default: "Install the parallex command"
        }
    }

    private var toolDetail: String {
        switch tool {
        case .linked(let url): url.path
        case .separate(let url): "\(url.path) — replace it with the app's copy so they update together."
        default: "Adds parallex to your PATH."
        }
    }

    private var toolButton: String {
        if case .separate = tool { return "Use App's Copy" }
        return "Install"
    }

    private func installTool() {
        toolError = nil
        do {
            let link = try CommandLineTool.install()
            if !CommandLineTool.isOnPath(link.deletingLastPathComponent()) {
                toolError = "Installed at \(link.path). Add \(link.deletingLastPathComponent().path) to your PATH to use it."
            }
        } catch {
            toolError = "Couldn't install the command: \(error.localizedDescription)"
        }
        tool = CommandLineTool.status()
    }
}

// MARK: - Usage preview

/// Exactly what the weekly usage report would send, from this Mac, now.
private struct UsagePreview: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("What's sent").font(Theme.Font.title)
            Text("This is the whole report, as it would go to parallex.mandip.dev today. It's added into counts there; nothing ties it to you.")
                .font(Theme.Font.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(text)
                    .font(Theme.Font.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.m)
            }
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.hairline))
            HStack {
                Link("What leaves your Mac", destination: URL(string: "https://parallex.mandip.dev/privacy")!)
                    .font(Theme.Font.callout)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 520, height: 520)
        .task {
            text = await Task.detached { String(decoding: UsageReport.make().json(), as: UTF8.self) }.value
        }
    }
}
