import Foundation
import ParallexKit

/// Opt-in usage, off until it's turned on in Settings: once a week, which
/// apps this Mac's instances copy and how those copies are doing, and which
/// features are in use. It carries no identifier, no instance names, no
/// paths and no website other than Parallex's own presets, and Settings
/// shows exactly this before anything is sent.
public struct UsageReport: Codable, Equatable, Sendable {
    public struct App: Codable, Equatable, Sendable {
        public var bundleID: String
        public var name: String
        public var appVersion: String
        /// "copy", "sandboxed copy" or "instance".
        public var kind: String
        public var instances: Int
        /// Copies of it have been quitting right after they open.
        public var quitsAtLaunch: Bool
        /// An isolation check of an instance of it passed on this Mac.
        public var verified: Bool
    }

    public var version: String
    public var os: String
    public var arch: String
    public var apps: [App]
    /// Apps copied that aren't clearly public (an in-house app, say): only
    /// how many.
    public var otherApps: Int
    /// Parallex's website presets in use ("web.whatsapp.com"), and how many
    /// other sites (never which).
    public var websites: [String]
    public var otherWebsites: Int
    /// How many instances use each feature (workspaces: how many there are).
    public var features: [String: Int]

    public static let endpoint = URL(string: "https://parallex.mandip.dev/api/v1/usage")!

    /// Well-known apps anyone can download, which are named in the report.
    static let publicApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.microsoft.teams2", "com.microsoft.teams", "us.zoom.xos",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "org.mozilla.firefox", "com.brave.Browser",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "org.chromium.Chromium", "com.operasoftware.Opera",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
        "com.exafunction.windsurf", "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.jetbrains.WebStorm", "com.sublimetext.4",
        "com.spotify.client", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "ru.keepcoder.Telegram", "org.telegram.desktop",
        "org.whispersystems.signal-desktop", "com.facebook.archon", "com.facebook.archon.developerID", "com.skype.skype",
        "notion.id", "md.obsidian", "com.figma.Desktop", "com.linear", "com.anthropic.claudefordesktop", "com.openai.chat",
        "com.openai.codex", "com.electron.logseq", "com.bitwarden.desktop", "com.1password.1password", "com.postmanlabs.mac",
        "com.github.GitHubClient", "com.docker.docker", "com.getdropbox.dropbox", "com.microsoft.Outlook", "com.microsoft.Word",
        "com.microsoft.Excel", "com.microsoft.Powerpoint", "com.microsoft.onenote.mac", "com.readdle.smartemail-Mac",
        "com.superhuman.electron", "com.culturedcode.ThingsMac", "com.todoist.mac.Todoist", "com.agilebits.onepassword7",
        "com.colliderli.iina", "org.videolan.vlc", "com.mitchellh.ghostty", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.raycast.macos", "com.tdesktop.Telegram", "com.webex.meetingmanager", "com.cisco.webexmeetingsapp",
        "com.loom.desktop", "com.clickup.desktop-app", "com.asana.app", "com.trello.desktop", "com.airtable.airtable",
        "com.canva.CanvaDesktop", "com.adobe.acc.AdobeCreativeCloud", "com.bohemiancoding.sketch3", "com.framer.electron",
        "com.cron.electron", "com.amie.desktop", "com.readdle.PDFExpert-Mac", "com.evernote.Evernote", "com.bear-writer",
        "com.ulyssesapp.mac", "com.tableplus.TablePlus", "com.sequel-ace.sequel-ace", "com.insomnia.app", "io.balena.etcher",
        "com.utmapp.UTM", "com.parallels.desktop.console", "org.m0k.transmission", "com.plexapp.plexmediaserver",
        "tv.plex.desktop", "com.amazon.Kindle", "com.valvesoftware.steam", "com.epicgames.EpicGamesLauncher",
        "com.blizzard.bnetlauncher", "com.mojang.minecraftlauncher", "com.riotgames.RiotGames.RiotClient",
    ]

    /// Whether an app can be named: Apple's own, one from the App Store, or
    /// a well-known app. Others (built in-house, say) are only counted.
    static func isPublic(_ appPath: String, bundleID: String) -> Bool {
        if bundleID.hasPrefix("com.apple.") || publicApps.contains(bundleID) { return true }
        return FileManager.default.fileExists(atPath: appPath + "/Contents/_MASReceipt/receipt")
    }

    /// The app's own name (not its file's, which may have been renamed).
    static func bundleName(of appPath: String, fallback: String) -> String {
        let info = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist")
        return info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String ?? fallback
    }

    public static func make(
        manifests: [InstanceManifest] = InstanceStore.loadAll(),
        workspaces: [Workspace] = WorkspaceStore.load(),
        links: LinkRouting.Configuration = LinkRouting.loadConfiguration(),
        quickExits: [String: Compatibility.Record] = Compatibility.load(),
        verified: [String: Verification.Record] = Verification.load()
    ) -> UsageReport {
        var apps: [String: App] = [:]
        var otherApps = Set<String>()
        var websites = Set<String>()
        var otherWebsites = 0
        let presetHosts = Set(WebShell.presets.compactMap { URL(string: $0.url)?.host })
        for manifest in manifests {
            if let site = manifest.webURL {
                if let host = site.host, presetHosts.contains(host) {
                    websites.insert(host)
                } else {
                    otherWebsites += 1
                }
                continue
            }
            guard let bundleID = manifest.knownTargetBundleID else { continue }
            guard isPublic(manifest.targetApp, bundleID: bundleID) else {
                otherApps.insert(bundleID)
                continue
            }
            let kind = manifest.clone == nil ? "instance" : manifest.clone?.usesLauncher == false ? "sandboxed copy" : "copy"
            let version = CompatibilityReport.shortVersion(
                manifest.clone?.sourceVersion ?? AppCloner.version(of: URL(fileURLWithPath: manifest.targetApp))
            )
            // Only trouble seen with this version of the app counts.
            let failing = quickExits[bundleID].map {
                $0.quickExits > 0 && CompatibilityReport.shortVersion($0.version ?? "") == version
            } ?? false
            let checked = verified[bundleID].map { CompatibilityReport.shortVersion($0.version ?? "") == version } ?? false
            var app = apps[bundleID] ?? App(
                bundleID: bundleID, name: bundleName(of: manifest.targetApp, fallback: manifest.targetDisplayName),
                appVersion: version, kind: kind, instances: 0, quitsAtLaunch: failing, verified: checked
            )
            app.instances += 1
            // A copy says more about how the app does than a plain instance.
            if kind != "instance" { app.kind = kind }
            apps[bundleID] = app
        }

        var features: [String: Int] = ["workspaces": workspaces.count]
        func count(_ name: String, _ test: (InstanceSettings) -> Bool) {
            features[name] = manifests.filter { test($0.effectiveSettings) }.count
        }
        count("throwaway") { $0.throwaway == true }
        count("hideFromDock") { $0.hideFromDock == true }
        count("menuBarIcon") { $0.menuBarIcon == true }
        count("shortcut") { $0.shortcut != nil }
        count("quitWhenUnused") { $0.quitWhenUnused != nil }
        count("openAtLaunch") { $0.openAtLaunch == true }
        count("shareMCPServers") { $0.enabledOptions?.contains("share-mcp-servers") == true }
        features["signInLinks"] = links.enabled ? 1 : 0
        features["webLinks"] = links.web == true ? 1 : 0

        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return UsageReport(
            version: ParallexConfig.version,
            os: "\(os.majorVersion).\(os.minorVersion)",
            arch: arch,
            apps: apps.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            otherApps: otherApps.count,
            websites: websites.sorted(),
            otherWebsites: otherWebsites,
            features: features
        )
    }

    /// The report as it's sent (and as Settings shows it).
    public func json() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }

    public func send(session: URLSession = .shared) async throws {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Parallex/\(ParallexConfig.version)", forHTTPHeaderField: "User-Agent")
        request.httpBody = json()
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ParallexError("The usage report wasn't taken (\(http.statusCode)).")
        }
    }
}
