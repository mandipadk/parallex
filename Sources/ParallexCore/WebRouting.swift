import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

/// Where a web link opens: a browser, one profile of a Chromium browser, or
/// a Parallex instance (a browser's copy or wrapper).
public enum WebLinkTarget: Codable, Sendable, Hashable {
    case browser(path: String)
    case profile(browser: String, directory: String, name: String)
    case instance(slug: String)
}

/// "Always open this site in …".
public struct WebLinkRule: Codable, Sendable, Hashable {
    /// A host, matching it and its subdomains ("northwind.com").
    public var domain: String
    public var target: WebLinkTarget

    public init(domain: String, target: WebLinkTarget) {
        self.domain = domain
        self.target = target
    }
}

/// Web links follow the instance they came from. When on, Parallex Links is
/// the default browser: a link opened by an instance goes to the browser
/// its workspace names, sites with a rule go where the rule says, and
/// everything else goes to the browser you had before, as if Parallex
/// weren't there.
public enum WebRouting {
    public static let schemes = ["http", "https"]

    // MARK: - Deciding

    /// Where `url` should open, given who opened it; nil for your usual
    /// browser. A site rule wins over the sender's workspace.
    public static func target(
        for url: URL,
        sender: pid_t?,
        rules: [WebLinkRule],
        workspaces: [Workspace],
        instanceOwning: (pid_t) -> String?
    ) -> WebLinkTarget? {
        if let host = url.host?.lowercased(), let rule = matchingRule(for: host, in: rules) {
            return rule.target
        }
        guard let sender, let slug = instanceOwning(sender) else { return nil }
        return workspaces.first { $0.members.contains(slug) && $0.webLinks != nil }?.webLinks
    }

    /// The most specific rule for a host: "app.northwind.com" beats
    /// "northwind.com".
    static func matchingRule(for host: String, in rules: [WebLinkRule]) -> WebLinkRule? {
        rules
            .filter { rule in
                let domain = normalizedDomain(rule.domain)
                return !domain.isEmpty && (host == domain || host.hasSuffix("." + domain))
            }
            .max { normalizedDomain($0.domain).count < normalizedDomain($1.domain).count }
    }

    /// "https://www.Northwind.com/x" or "*.northwind.com" → "northwind.com".
    public static func normalizedDomain(_ input: String) -> String {
        var domain = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: domain), let host = url.host, url.scheme != nil {
            domain = host
        }
        for prefix in ["*.", "www."] where domain.hasPrefix(prefix) {
            domain.removeFirst(prefix.count)
        }
        while domain.hasSuffix(".") || domain.hasSuffix("/") {
            domain.removeLast()
        }
        return domain
    }

    /// The instance a process belongs to: its own process, or one of its
    /// helpers (Electron opens links from helper processes too).
    public static func instance(owning pid: pid_t, running: [String: pid_t]) -> String? {
        let bySlug = Dictionary(running.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        var current = pid
        for _ in 0..<12 {
            if let slug = bySlug[current] {
                return slug
            }
            guard let parent = parentPID(of: current), parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        return pid_t(info.pbi_ppid)
    }

    // MARK: - Browsers and profiles

    public struct Browser: Sendable, Hashable, Identifiable {
        public let url: URL
        public let name: String
        public let bundleID: String
        public var id: String { url.path }
    }

    /// Browsers: apps that open web links and web pages (ChatGPT and others
    /// claim https links without being one), except Parallex's own.
    public static func browsers() -> [Browser] {
        nonisolated(unsafe) var apps: [URL] = []
        onMainThread {
            let pages = Set(NSWorkspace.shared.urlsForApplications(toOpen: .html).map(\.standardizedFileURL))
            apps = NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)
                .filter { pages.contains($0.standardizedFileURL) }
        }
        var seen = Set<String>()
        return apps.compactMap { url -> Browser? in
            guard !LinkRouting.isParallexBundle(url), let bundleID = AppInspectorLite.bundleID(of: url),
                  seen.insert(bundleID).inserted
            else { return nil }
            let name = (try? AppInspector.inspect(url).name) ?? url.deletingPathExtension().lastPathComponent
            return Browser(url: url, name: name, bundleID: bundleID)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public struct Profile: Sendable, Hashable, Identifiable {
        public let browser: URL
        public let browserName: String
        public let directory: String
        public let name: String
        public var id: String { browser.path + "/" + directory }
        public var target: WebLinkTarget { .profile(browser: browser.path, directory: directory, name: name) }
    }

    /// Where Chromium browsers keep their profiles (and "Local State", which
    /// names them), under ~/Library/Application Support.
    static let profileFolders: [String: String] = [
        "com.google.Chrome": "Google/Chrome",
        "com.google.Chrome.beta": "Google/Chrome Beta",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "org.chromium.Chromium": "Chromium",
    ]

    /// The profiles of the Chromium browsers installed here (only when a
    /// browser has more than one; with one there's nothing to choose).
    public static func profiles(
        in browsers: [Browser],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [Profile] {
        var profiles: [Profile] = []
        for browser in browsers {
            guard let folder = profileFolders[browser.bundleID] else { continue }
            let localState = home.appendingPathComponent("Library/Application Support/\(folder)/Local State")
            let found = readProfiles(localState).map {
                Profile(browser: browser.url, browserName: browser.name, directory: $0.directory, name: $0.name)
            }
            if found.count > 1 {
                profiles += found
            }
        }
        return profiles
    }

    static func readProfiles(_ localState: URL) -> [(directory: String, name: String)] {
        guard let data = try? Data(contentsOf: localState),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any]
        else { return [] }
        return cache.compactMap { directory, value in
            guard let info = value as? [String: Any], OriginalData.isPlainName(directory) else { return nil }
            return (directory, (info["name"] as? String) ?? directory)
        }
        .sorted { $0.directory.localizedStandardCompare($1.directory) == .orderedAscending }
    }

    /// A target from words: "default" (your usual browser), an instance's
    /// name, "<Browser>/<Profile>" ("Chrome/Work"), or a browser's name or
    /// path.
    public static func resolveTarget(
        _ text: String,
        manifests: [InstanceManifest],
        browsers: [Browser],
        profiles: [Profile]
    ) throws -> WebLinkTarget? {
        let wanted = text.trimmingCharacters(in: .whitespaces)
        func same(_ lhs: String, _ rhs: String) -> Bool { lhs.caseInsensitiveCompare(rhs) == .orderedSame }
        if ["default", "usual", "none"].contains(wanted.lowercased()) {
            return nil
        }
        let browserIDs = Set(browsers.map(\.bundleID))
        if let manifest = manifests.first(where: { same($0.name, wanted) }) {
            // A link sent to an instance that isn't a browser goes nowhere
            // (or straight back to the router).
            guard browserIDs.contains(manifest.knownTargetBundleID ?? "") else {
                throw ParallexError("“\(manifest.name)” isn't a browser. Choose a browser, a profile, or an instance of a browser.")
            }
            return .instance(slug: manifest.slug)
        }
        if let slash = wanted.lastIndex(of: "/"), !wanted.hasSuffix(".app") {
            let browser = String(wanted[..<slash])
            let profile = String(wanted[wanted.index(after: slash)...])
            if let match = profiles.first(where: {
                (same($0.browserName, browser) || $0.browserName.localizedCaseInsensitiveContains(browser))
                    && (same($0.name, profile) || same($0.directory, profile))
            }) {
                return match.target
            }
        }
        if let browser = browsers.first(where: { same($0.name, wanted) || same($0.url.path, wanted) }) {
            return .browser(path: browser.url.path)
        }
        if wanted.hasSuffix(".app"), FileManager.default.fileExists(atPath: wanted) {
            return .browser(path: wanted)
        }
        let known = browsers.map(\.name) + profiles.map { "\($0.browserName)/\($0.name)" }
        throw ParallexError("No instance, browser or profile called “\(wanted)”. Try: default, \(known.joined(separator: ", ")).")
    }

    /// Words for a target, for lists and menus.
    public static func describe(_ target: WebLinkTarget?, manifests: [InstanceManifest]) -> String {
        switch target {
        case nil:
            return "Your usual browser"
        case .browser(let path):
            return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        case .profile(let browser, _, let name):
            return "\(URL(fileURLWithPath: browser).deletingPathExtension().lastPathComponent), profile “\(name)”"
        case .instance(let slug):
            return manifests.first { $0.slug == slug }?.name ?? slug
        }
    }

    // MARK: - Opening

    /// Open `url` in `target` (nil: the browser you had before). Never hands
    /// it to a Parallex bundle that isn't the target instance, so a link
    /// can't loop back into the router, and never drops it: whatever fails
    /// falls back to your usual browser. `completion` runs once it's handed
    /// over.
    public static func open(
        _ url: URL,
        in target: WebLinkTarget?,
        fallback: URL?,
        manifests: [InstanceManifest],
        running: [String: pid_t] = [:],
        completion: @escaping @Sendable () -> Void
    ) {
        let usual: @Sendable () -> Void = {
            openInBrowser(url, fallback, avoiding: running, manifests: manifests, completion: completion)
        }
        switch target {
        case .instance(let slug):
            guard let manifest = manifests.first(where: { $0.slug == slug }) else { return usual() }
            if let pid = running[slug] ?? Running.processID(of: manifest) {
                if (try? LinkRouting.deliver(url, to: pid)) != nil {
                    completion()
                } else {
                    usual()
                }
                return
            }
            // Not running: start it with the link, which the launcher
            // passes on to the app.
            guard FileManager.default.fileExists(atPath: manifest.wrapperPath) else { return usual() }
            run("/usr/bin/open", ["-a", manifest.wrapperPath, "--args", url.absoluteString], onSuccess: completion, onFailure: usual)
        case .profile(let browser, let directory, _):
            // Chromium passes the link to the running browser, in that profile.
            guard FileManager.default.fileExists(atPath: browser) else { return usual() }
            run("/usr/bin/open", ["-na", browser, "--args", "--profile-directory=\(directory)", url.absoluteString],
                onSuccess: completion, onFailure: usual)
        case .browser(let path):
            openInBrowser(url, URL(fileURLWithPath: path), avoiding: running, manifests: manifests) {
                completion()
            }
        case nil:
            usual()
        }
    }

    /// Open in a browser app itself — not in an instance of it that happens
    /// to be running (macOS would hand the link to whichever process it
    /// last saw with that app's identity).
    static func openInBrowser(
        _ url: URL, _ preferred: URL?,
        avoiding running: [String: pid_t] = [:], manifests: [InstanceManifest] = [],
        completion: @escaping @Sendable () -> Void
    ) {
        func usable(_ app: URL) -> Bool {
            FileManager.default.fileExists(atPath: app.path) && !LinkRouting.isParallexBundle(app)
        }
        let app: URL
        if let preferred, usable(preferred) {
            app = preferred
        } else if let first = browsers().map(\.url).first(where: usable) {
            app = first
        } else {
            completion()
            return
        }
        let bundleID = AppInspectorLite.bundleID(of: app) ?? ""
        let instancesOfIt = Set(manifests.filter { $0.knownTargetBundleID == bundleID && $0.clone == nil }
            .compactMap { running[$0.slug] })
        onMainThread {
            let configuration = NSWorkspace.OpenConfiguration()
            // An instance is running as this app: start (or reach) the app
            // itself rather than handing the link to the instance.
            if !instancesOfIt.isEmpty,
               NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .contains(where: { instancesOfIt.contains($0.processIdentifier) }) {
                configuration.createsNewApplicationInstance = true
            }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, _ in
                completion()
            }
        }
    }

    private static func run(
        _ tool: String, _ arguments: [String],
        onSuccess: @escaping @Sendable () -> Void, onFailure: @escaping @Sendable () -> Void
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = InstanceLauncher.cleanEnvironment()
        process.terminationHandler = { finished in
            finished.terminationStatus == 0 ? onSuccess() : onFailure()
        }
        do {
            try process.run()
        } catch {
            onFailure()
        }
    }
}
