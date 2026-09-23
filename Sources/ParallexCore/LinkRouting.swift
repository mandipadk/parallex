import AppKit
import Foundation

/// Sign-in link routing. Apps finish sign-in by opening a link in their own
/// scheme (`claude://…`, `cursor://…`). With several copies of an app
/// running — the original and its instances all under one identity —
/// macOS hands that link to whichever copy it picks, often the wrong one.
///
/// When routing is on, a small background app ("Parallex Links") is the
/// default handler for those schemes. It picks the copy the link is meant
/// for — the one used most recently, or the user's choice — and delivers the
/// link to that exact process with an Apple Event.
public enum LinkRouting {
    public struct Configuration: Codable, Sendable, Equatable {
        public var enabled: Bool = false
        /// Scheme → the app that handled it before Parallex took over, so
        /// links can be opened normally when no copy is running and the
        /// original handler restored when routing is turned off.
        public var schemes: [String: String] = [:]
        /// Ask every time several copies are running, instead of choosing the
        /// most recently used one.
        public var alwaysAsk: Bool = false

        public init() {}
    }

    public static let routerName = "Parallex Links"
    static let routerBundleIDPrefix = "com.parallex.links"

    /// One router per registry: a second registry (PARALLEX_HOME, used in
    /// development) must never receive — or be mistaken for — the main one.
    public static var routerBundleID: String {
        let defaultRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parallex", isDirectory: true)
        guard Paths.supportRoot.standardizedFileURL.path != defaultRoot.standardizedFileURL.path else {
            return routerBundleIDPrefix
        }
        var hash: UInt64 = 5381
        for byte in Paths.supportRoot.standardizedFileURL.path.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return "\(routerBundleIDPrefix).r\(String(hash, radix: 16))"
    }

    /// Parallex's own bundles (routers, instance wrappers and copies) — never
    /// a scheme's "original" handler.
    static func isParallexBundle(_ app: URL) -> Bool {
        guard let bundleID = AppInspectorLite.bundleID(of: app) else { return false }
        return bundleID.hasPrefix(routerBundleIDPrefix) || bundleID.hasPrefix("com.parallex.instance.")
            || BundleBuilder.isParallexWrapper(app)
    }

    static var configURL: URL { Paths.supportRoot.appendingPathComponent("links.json") }
    static var historyURL: URL { Paths.supportRoot.appendingPathComponent("activation-history.json") }
    public static var routerAppURL: URL { Paths.supportRoot.appendingPathComponent("\(routerName).app", isDirectory: true) }

    public static func loadConfiguration() -> Configuration {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(Configuration.self, from: data)
        else {
            return Configuration()
        }
        return config
    }

    static func save(_ config: Configuration) throws {
        try FileManager.default.createDirectory(at: Paths.supportRoot, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }

    // MARK: - Schemes

    /// Schemes that belong to the system or the browser; never taken over.
    static let excludedSchemes: Set<String> = [
        "http", "https", "file", "mailto", "ftp", "sftp", "ssh", "tel", "sms", "data", "about", "javascript",
    ]

    /// The custom URL schemes an app declares.
    public static func schemes(ofApp app: URL) -> [String] {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let types = plist["CFBundleURLTypes"] as? [[String: Any]]
        else {
            return []
        }
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }.map { $0.lowercased() }
        return Array(Set(schemes.filter { !excludedSchemes.contains($0) })).sorted()
    }

    /// Schemes used by the apps that have instances: what routing covers.
    public static func routableSchemes(_ manifests: [InstanceManifest]) -> [String: String] {
        var result: [String: String] = [:]
        for manifest in manifests {
            for scheme in schemes(ofApp: URL(fileURLWithPath: manifest.targetApp)) where result[scheme] == nil {
                result[scheme] = manifest.targetApp
            }
        }
        return result
    }

    // MARK: - Candidates

    /// One running copy that could receive a link.
    public struct Candidate: Sendable, Equatable {
        public let pid: pid_t
        /// Instance name, or the app's name for the original.
        public let name: String
        public let isInstance: Bool
    }

    /// Running copies of the app that owns `scheme`: instances (by pid file
    /// or clone identity) and the original itself.
    public static func candidates(for scheme: String, manifests: [InstanceManifest]) -> [Candidate] {
        var result: [Candidate] = []
        var instancePIDs = Set<pid_t>()
        var originals: [String: String] = [:] // bundle ID → app name
        for manifest in manifests {
            let target = URL(fileURLWithPath: manifest.targetApp)
            guard schemes(ofApp: target).contains(scheme) else { continue }
            if let pid = Running.processID(of: manifest) {
                instancePIDs.insert(pid)
                result.append(Candidate(pid: pid, name: manifest.name, isInstance: true))
            }
            if let bundleID = manifest.knownTargetBundleID ?? AppInspectorLite.bundleID(of: target) {
                originals[bundleID] = target.deletingPathExtension().lastPathComponent
            }
        }
        for (bundleID, name) in originals {
            nonisolated(unsafe) var pids: [pid_t] = []
            onMainThread {
                pids = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier)
            }
            for pid in pids where !instancePIDs.contains(pid) {
                result.append(Candidate(pid: pid, name: "\(name) (original)", isInstance: false))
            }
        }
        return result
    }

    // MARK: - Activation history (written by Parallex.app)

    /// Record that `pid` became the active app. Keeps the most recent
    /// activations so the router can tell which copy the user was just in.
    public static func recordActivation(pid: pid_t, at date: Date = Date()) {
        var history = loadHistory()
        history[String(pid)] = date.timeIntervalSince1970
        if history.count > 64 {
            let keep = history.sorted { $0.value > $1.value }.prefix(64)
            history = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(history) {
            try? FileManager.default.createDirectory(at: Paths.supportRoot, withIntermediateDirectories: true)
            try? data.write(to: historyURL, options: .atomic)
        }
    }

    static func loadHistory() -> [String: Double] {
        guard let data = try? Data(contentsOf: historyURL),
              let history = try? JSONDecoder().decode([String: Double].self, from: data)
        else {
            return [:]
        }
        return history
    }

    /// The candidate the link is most likely meant for: the one the user
    /// activated most recently (sign-in starts in the app, then hops to the
    /// browser, which opens the link). `nil` when there's no history to go on.
    public static func mostRecent(_ candidates: [Candidate], history: [String: Double]? = nil) -> Candidate? {
        let history = history ?? loadHistory()
        let ranked = candidates.compactMap { candidate in
            history[String(candidate.pid)].map { (candidate, $0) }
        }
        return ranked.max { $0.1 < $1.1 }?.0
    }

    // MARK: - Delivery

    /// Deliver a URL to one specific process (a GetURL Apple Event, what
    /// "open this link" sends) and bring it forward.
    public static func deliver(_ url: URL, to pid: pid_t) throws {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass),
            eventID: AEEventID(kAEGetURL),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: keyDirectObject)
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 10)
        } catch {
            let code = (error as NSError).code
            if code == -1743 { // errAEEventNotPermitted
                throw ParallexError(
                    "macOS blocked Parallex Links from passing the link on. Allow it in System Settings › "
                    + "Privacy & Security › Automation."
                )
            }
            throw ParallexError("Couldn't pass the link to the app (Apple Event error \(code)).")
        }
        InstanceLauncher.activate(pid: pid)
    }

    /// Open a link with the app that handled the scheme before routing —
    /// used when no copy is running.
    ///
    /// Never hands the link to a Parallex bundle (that could loop back into
    /// a router); `completion` runs once the open request has gone through.
    public static func openNormally(_ url: URL, config: Configuration, completion: @escaping @Sendable () -> Void) {
        let scheme = url.scheme?.lowercased() ?? ""
        var candidates: [URL] = []
        if let handler = config.schemes[scheme] {
            candidates.append(URL(fileURLWithPath: handler))
        }
        nonisolated(unsafe) var registered: [URL] = []
        onMainThread { registered = NSWorkspace.shared.urlsForApplications(toOpen: url) }
        candidates += registered
        guard let app = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path) && !isParallexBundle($0)
        }) else {
            completion()
            return
        }
        onMainThread {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                completion()
            }
        }
    }

    // MARK: - Turning routing on and off

    /// Build the router app for the current instances' schemes and make it
    /// the default handler. macOS may ask the user to confirm each scheme.
    public static func enable(routerBinary: URL, manifests: [InstanceManifest]) async throws -> Configuration {
        var config = loadConfiguration()
        let schemes = routableSchemes(manifests)
        guard !schemes.isEmpty else {
            throw ParallexError("None of your instances' apps use custom link schemes, so there's nothing to route.")
        }
        // Schemes no instance uses any more go back to their own handler.
        for (scheme, handler) in config.schemes where schemes[scheme] == nil {
            if await restore(scheme, to: handler) {
                config.schemes[scheme] = nil
            }
        }
        // Record every previous handler before switching anything, so a
        // failure halfway can always be undone.
        for (scheme, app) in schemes where config.schemes[scheme] == nil {
            let current = currentHandler(for: scheme)
            config.schemes[scheme] = current.flatMap { isParallexBundle($0) ? nil : $0.path } ?? app
        }
        config.enabled = true
        try save(config)

        try buildRouterApp(binary: routerBinary, schemes: Array(schemes.keys).sorted())
        for scheme in schemes.keys.sorted() {
            try await NSWorkspace.shared.setDefaultApplication(at: routerAppURL, toOpenURLsWithScheme: scheme)
        }
        return config
    }

    /// Point a scheme back at the app that handled it before routing.
    static func restore(_ scheme: String, to handler: String) async -> Bool {
        let app = URL(fileURLWithPath: handler)
        guard FileManager.default.fileExists(atPath: app.path), !isParallexBundle(app) else {
            // Nothing sensible to restore to; the app registers itself again
            // the next time it starts.
            return true
        }
        return (try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme)) != nil
    }

    /// Apps like Claude, Cursor, and Codex register themselves as their
    /// scheme's handler every time they start, which undoes routing. Parallex
    /// calls this after such an app launches to take the schemes back.
    /// Returns the schemes it re-routed.
    @discardableResult
    public static func reassert() async -> [String] {
        let config = loadConfiguration()
        guard config.enabled, FileManager.default.fileExists(atPath: routerAppURL.path) else { return [] }
        // Only schemes an instance still uses.
        let wanted = routableSchemes(InstanceStore.loadAll())
        var rerouted: [String] = []
        for scheme in config.schemes.keys.sorted() where wanted[scheme] != nil && !isRouting(scheme) {
            if (try? await NSWorkspace.shared.setDefaultApplication(at: routerAppURL, toOpenURLsWithScheme: scheme)) != nil {
                rerouted.append(scheme)
            }
        }
        return rerouted
    }

    public static func setAlwaysAsk(_ ask: Bool) throws {
        var config = loadConfiguration()
        config.alwaysAsk = ask
        try save(config)
    }

    public static func disable() async throws {
        var config = loadConfiguration()
        // Off first, so nothing re-routes schemes while they're restored.
        config.enabled = false
        try save(config)
        for (scheme, handler) in config.schemes.sorted(by: { $0.key < $1.key }) {
            if await restore(scheme, to: handler) {
                config.schemes[scheme] = nil
            }
        }
        try save(config)
        guard config.schemes.isEmpty else {
            // Keep the router so those links still open; retry later.
            throw ParallexError(
                "Couldn't give \(config.schemes.keys.sorted().map { "\($0)://" }.joined(separator: ", ")) back to "
                + "its app. Run `parallex links disable` again."
            )
        }
        if let lsregister = BundleBuilder.lsregisterPath {
            Shell.runAllowingFailure(lsregister, ["-u", routerAppURL.path])
        }
        if FileManager.default.fileExists(atPath: routerAppURL.path) {
            try? FileManager.default.trashItem(at: routerAppURL, resultingItemURL: nil)
        }
    }

    public static func currentHandler(for scheme: String) -> URL? {
        guard let probe = URL(string: "\(scheme)://parallex-probe") else { return nil }
        nonisolated(unsafe) var handler: URL?
        onMainThread { handler = NSWorkspace.shared.urlForApplication(toOpen: probe) }
        return handler
    }

    /// Whether the router is currently what macOS uses for `scheme`.
    public static func isRouting(_ scheme: String) -> Bool {
        currentHandler(for: scheme)?.standardizedFileURL.path == routerAppURL.standardizedFileURL.path
    }

    static func buildRouterApp(binary: URL, schemes: [String]) throws {
        let fm = FileManager.default
        let app = routerAppURL
        let staging = fm.temporaryDirectory.appendingPathComponent("parallex-links-\(UUID().uuidString)")
        let bundle = staging.appendingPathComponent(app.lastPathComponent, isDirectory: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: binary, to: bundle.appendingPathComponent("Contents/MacOS/router"))
        var info: [String: Any] = [
            "CFBundleIdentifier": routerBundleID,
            "CFBundleName": routerName,
            "CFBundleDisplayName": routerName,
            "CFBundleExecutable": "router",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1",
            "CFBundleVersion": "1",
            "LSUIElement": true,
            "LSMinimumSystemVersion": "13.0",
            "NSAppleEventsUsageDescription":
                "Parallex Links passes sign-in links to the copy of the app that asked for them.",
            "CFBundleURLTypes": [[
                "CFBundleURLName": "Parallex routed links",
                "CFBundleURLSchemes": schemes,
            ]],
        ]
        // Read the same registry as the Parallex that built the router.
        if ProcessInfo.processInfo.environment["PARALLEX_HOME"] != nil {
            info["LSEnvironment"] = ["PARALLEX_HOME": Paths.supportRoot.path]
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path])
        try fm.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: app.path) {
            try fm.removeItem(at: app)
        }
        try fm.moveItem(at: bundle, to: app)
        if let lsregister = BundleBuilder.lsregisterPath {
            Shell.runAllowingFailure(lsregister, ["-f", app.path])
        }
    }
}

/// Minimal Info.plist reads that don't need a full `AppInspector` pass.
enum AppInspectorLite {
    static func bundleID(of app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else {
            return nil
        }
        return plist["CFBundleIdentifier"] as? String
    }
}
