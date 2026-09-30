import Foundation
import ParallexKit

/// Telemetry 2: what a Mac that shares usage tells Parallex's server once a
/// day. From 1.6 sharing is the default (new installs see it in onboarding;
/// earlier ones are asked once), with one switch that turns it all off.
///
/// What's sent: a random install number (tied to nothing, renewed every
/// 180 days), Parallex's version, macOS major.minor and chip; what this Mac
/// has (instance counts, well-known apps copied and their versions, features
/// in use); what happened since the last report, counted (an instance made,
/// a copy that quit at launch, a refresh, an update, a snapshot…); and
/// Parallex's own crashes and hangs, by where in Parallex's code they
/// happened. Never instance names, file names, paths, contents, or apps that
/// aren't well-known (those are only counted). Everything can be seen before
/// it goes (`parallex usage`, Settings › See What's Sent).
public enum Telemetry {
    public static let endpoint = URL(string: "https://parallex.mandip.dev/api/v2/report")!

    public enum Consent: String, Codable, Sendable {
        /// The default for new installs, or said yes to.
        case shared
        case declined
        /// An install from before 1.6 that hasn't been asked yet.
        case undecided
    }

    static var folder: URL { Paths.supportRoot.appendingPathComponent("telemetry", isDirectory: true) }
    static var consentFile: URL { folder.appendingPathComponent("consent.json") }
    static var installFile: URL { folder.appendingPathComponent("install.json") }
    static var pendingFile: URL { folder.appendingPathComponent("pending.json") }

    // MARK: Consent

    struct StoredConsent: Codable { var consent: Consent; var at: Date }

    /// Nothing stored means no choice has been made (see `Consent`).
    public static var consent: Consent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: consentFile),
              let stored = try? decoder.decode(StoredConsent.self, from: data)
        else { return .undecided }
        return stored.consent
    }

    public static var hasChosen: Bool { FileManager.default.fileExists(atPath: consentFile.path) }

    public static func setConsent(_ consent: Consent, at date: Date = Date()) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(StoredConsent(consent: consent, at: date)) {
            try? data.write(to: consentFile, options: .atomic)
        }
        // Declined: nothing waits to be sent (under the lock, so a record
        // under way can't put it back).
        if consent == .declined, let lock = try? FileLock(folder.appendingPathComponent(".lock")) {
            try? FileManager.default.removeItem(at: pendingFile)
            try? FileManager.default.removeItem(at: installFile)
            lock.release()
        }
    }

    /// When Parallex was first used on this Mac, when known (the app sets
    /// it at launch), for the week a first install number starts.
    nonisolated(unsafe) public static var firstUsed: Date?

    // MARK: Install number

    public struct Install: Codable, Sendable, Equatable {
        public var id: String
        public var created: Date
        /// ISO week of the first install number on this Mac ("2026-W40"),
        /// kept across renewals: which week's newcomers it belongs with.
        public var since: String
    }

    static let renewal: TimeInterval = 180 * 86_400

    /// `save`: false for a preview, which mustn't leave a number behind on
    /// a Mac that doesn't share. `firstUsed`: when Parallex was first used
    /// here, if known (the app knows), for the week a first number starts.
    public static func install(now: Date = Date(), save: Bool = true, firstUsed: Date? = Telemetry.firstUsed) -> Install {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let existing = (try? Data(contentsOf: installFile)).flatMap { try? decoder.decode(Install.self, from: $0) }
        if let existing, now.timeIntervalSince(existing.created) < renewal, existing.created <= now {
            return existing
        }
        let fresh = Install(id: UUID().uuidString.lowercased(), created: now, since: existing?.since ?? week(of: min(firstUsed ?? now, now)))
        guard save else { return fresh }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(fresh) { try? data.write(to: installFile, options: .atomic) }
        return fresh
    }

    static func week(of date: Date) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 2026, parts.weekOfYear ?? 1)
    }

    // MARK: Events

    public struct Event: Codable, Sendable, Hashable {
        public var name: String
        public var props: [String: String]
        public var n: Int
        /// The Parallex that recorded it (a report sent after an update
        /// still credits what happened before to the version it happened on).
        public var version: String?
    }

    public struct Frame: Codable, Sendable, Hashable {
        public var binary: String
        public var uuid: String
        public var offset: UInt64
    }

    public struct Crash: Codable, Sendable, Hashable {
        /// "crash" or "hang".
        public var kind: String
        public var signal: Int?
        public var exceptionType: Int?
        public var frames: [Frame]
        public var n: Int
        /// The Parallex it happened in (macOS reports it at a later launch,
        /// often after an update).
        public var version: String?

        func isSame(as other: Crash) -> Bool {
            kind == other.kind && signal == other.signal && exceptionType == other.exceptionType
                && frames == other.frames && version == other.version
        }
    }

    struct Pending: Codable {
        var events: [Event] = []
        var crashes: [Crash] = []
    }

    static let maxEvents = 200
    static let maxCrashes = 20

    /// Where this was done: the app, the command-line tool, Shortcuts.
    public static var source: String {
        switch ProcessInfo.processInfo.processName {
        case "parallex": return "cli"
        default: return "app"
        }
    }

    /// Only while this Mac shares usage: nothing is kept before it's said
    /// yes to, or after it's turned off.
    private static func withPending(_ change: (inout Pending) -> Void) {
        guard consent == .shared else { return }
        guard let lock = try? FileLock(folder.appendingPathComponent(".lock")) else { return }
        defer { lock.release() }
        guard consent == .shared else { return }
        var pending = (try? Data(contentsOf: pendingFile)).flatMap { try? JSONDecoder().decode(Pending.self, from: $0) } ?? Pending()
        change(&pending)
        if let data = try? JSONEncoder().encode(pending) { try? data.write(to: pendingFile, options: .atomic) }
    }

    /// Count that `name` happened (with `props`, which only ever hold kinds,
    /// results and well-known apps' bundle IDs).
    public static func record(_ name: String, _ props: [String: String] = [:], n: Int = 1, version: String = ParallexConfig.version) {
        withPending { pending in
            if let index = pending.events.firstIndex(where: { $0.name == name && $0.props == props && $0.version == version }) {
                pending.events[index].n += n
            } else if pending.events.count < maxEvents {
                pending.events.append(Event(name: name, props: props, n: n, version: version))
            }
        }
    }

    /// A Parallex crash or hang (see `CrashReports`): frames in Parallex's
    /// own binaries only.
    public static func recordCrash(_ crash: Crash) {
        withPending { pending in
            if let index = pending.crashes.firstIndex(where: { $0.isSame(as: crash) }) {
                pending.crashes[index].n += crash.n
            } else if pending.crashes.count < maxCrashes {
                pending.crashes.append(crash)
            }
        }
    }

    /// An app's bundle ID if it's a well-known one (see `UsageReport`),
    /// "other" otherwise.
    public static func appName(for manifest: InstanceManifest) -> String {
        guard let bundleID = manifest.knownTargetBundleID,
              UsageReport.isPublic(manifest.targetApp, bundleID: bundleID)
        else { return "other" }
        return bundleID
    }

    /// What an instance is, for counting what happens to it: its kind,
    /// and a well-known app's bundle ID and version ("other" and no version
    /// for any other app).
    public static func facts(of manifest: InstanceManifest) -> [String: String] {
        var facts = ["kind": kind(of: manifest), "app": appName(for: manifest)]
        let version = AppCloner.version(of: URL(fileURLWithPath: manifest.targetApp)).split(separator: " ").first.map(String.init)
        if facts["app"] != "other", !manifest.isWeb, let version, version != "?" {
            facts["version"] = version
        }
        return facts
    }

    public static func kind(of manifest: InstanceManifest) -> String {
        if manifest.isWeb { return "web" }
        guard let clone = manifest.clone else { return "wrapper" }
        return clone.usesLauncher ? "copy" : "sandboxed copy"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        seconds < 5 ? "<5s" : seconds < 15 ? "<15s" : seconds < 60 ? "<60s" : "60s+"
    }

    /// Parallex's own binaries: the only frames a crash report keeps.
    public static let ownBinaries: Set<String> = [
        "Parallex", "parallex", "parallex-launcher", "parallex-router", "parallex-web",
        "libparallexhome.dylib", "libparallexgroups.dylib",
    ]

    /// A crash or hang from MetricKit's call stack tree (its JSON form): the
    /// stack of the thread it's attributed to, top first, keeping only
    /// frames in Parallex's own binaries. Nil when none are (a crash in
    /// macOS or another app's code isn't Parallex's to report).
    public static func crash(
        kind: String, callStackTree json: Data, signal: Int? = nil, exceptionType: Int? = nil, version: String? = nil
    ) -> Crash? {
        guard let tree = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let stacks = tree["callStacks"] as? [[String: Any]]
        else { return nil }
        let stack = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
        var frames: [Frame] = []
        var level = stack?["callStackRootFrames"] as? [[String: Any]] ?? []
        // Each thread's stack is a chain: a frame, and the one that called it
        // as its only sub-frame.
        while let frame = level.first, frames.count < 12 {
            if let binary = frame["binaryName"] as? String, ownBinaries.contains(binary),
               let uuid = frame["binaryUUID"] as? String,
               let offset = (frame["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value {
                frames.append(Frame(binary: binary, uuid: uuid, offset: offset))
            }
            level = frame["subFrames"] as? [[String: Any]] ?? []
        }
        guard !frames.isEmpty else { return nil }
        return Crash(kind: kind, signal: signal, exceptionType: exceptionType, frames: frames, n: 1, version: version)
    }

    // MARK: The report

    public struct Gauge: Codable, Sendable, Hashable {
        public var name: String
        public var props: [String: String]
        public var value: Int
    }

    public struct Report: Codable, Sendable {
        public var schema = 2
        public var install: String
        public var since: String
        public var version: String
        public var os: String
        public var arch: String
        public var gauges: [Gauge]
        public var events: [Event]
        public var crashes: [Crash]
    }

    /// Today's report: what this Mac has, and what's happened since the
    /// last one.
    /// `preview`: for showing, not sending (see `install`).
    public static func make(
        now: Date = Date(), manifests: [InstanceManifest] = InstanceStore.loadAll(), preview: Bool = false
    ) -> Report {
        let usage = UsageReport.make(manifests: manifests)
        let install = install(now: now, save: !preview)
        var gauges: [Gauge] = []
        var kinds: [String: Int] = [:]
        for manifest in manifests { kinds[kind(of: manifest), default: 0] += 1 }
        for (kind, count) in kinds.sorted(by: { $0.key < $1.key }) {
            gauges.append(Gauge(name: "instances", props: ["kind": kind], value: count))
        }
        for app in usage.apps {
            var props = ["app": app.bundleID, "kind": app.kind == "instance" ? "wrapper" : app.kind]
            // Left out rather than refused when they can't be read or are
            // unusually long.
            if !app.appVersion.isEmpty, app.appVersion != "?", app.appVersion.count <= 30 { props["version"] = app.appVersion }
            if !app.name.isEmpty, app.name.count <= 40 { props["name"] = app.name }
            gauges.append(Gauge(name: "app", props: props, value: app.instances))
        }
        if usage.otherApps > 0 { gauges.append(Gauge(name: "app.other", props: [:], value: usage.otherApps)) }
        for host in usage.websites {
            gauges.append(Gauge(name: "website", props: ["app": host], value: 1))
        }
        if usage.otherWebsites > 0 { gauges.append(Gauge(name: "website.other", props: [:], value: usage.otherWebsites)) }
        var features = usage.features
        func count(_ name: String, _ test: (InstanceManifest) -> Bool) {
            features[name] = manifests.filter(test).count
        }
        count("snapshots") { !Snapshots.list($0).isEmpty }
        count("dailySnapshots") { $0.effectiveSettings.dailySnapshots == true }
        count("pinnedVersion") { $0.effectiveSettings.pinnedVersion != nil }
        count("shareSettings") { $0.sharedSettings?.isEmpty == false }
        count("guard") { $0.guardedPaths?.isEmpty == false }
        count("separateKeychain") { $0.instanceKeychain != nil }
        count("privateItems") { $0.effectiveSettings.extraPrivateItems?.isEmpty == false }
        let workspaces = WorkspaceStore.load()
        features["persona"] = workspaces.filter { $0.persona == true }.count
        features["proxy"] = workspaces.filter { $0.proxy != nil }.count
        for (feature, value) in features.sorted(by: { $0.key < $1.key }) where value > 0 {
            gauges.append(Gauge(name: "feature", props: ["feature": feature], value: value))
        }
        let blocked = manifests.reduce(0) { total, manifest in
            total + (manifest.guardedPaths == nil ? 0 : (IsolationCheck.recorded(manifest)?.blocked.count ?? 0))
        }
        if blocked > 0 { gauges.append(Gauge(name: "guard.blocked", props: [:], value: blocked)) }

        let pending = (try? Data(contentsOf: pendingFile)).flatMap { try? JSONDecoder().decode(Pending.self, from: $0) } ?? Pending()
        return Report(
            install: install.id, since: install.since, version: usage.version, os: usage.os, arch: usage.arch,
            gauges: gauges, events: pending.events, crashes: pending.crashes
        )
    }

    public static func json(_ report: Report) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(report)) ?? Data()
    }

    /// Send it; once it's taken, what it carried is no longer pending
    /// (what happened meanwhile stays for the next one).
    public static func send(_ report: Report, session: URLSession = .shared) async throws {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Parallex/\(ParallexConfig.version)", forHTTPHeaderField: "User-Agent")
        request.httpBody = json(report)
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ParallexError("The report wasn't taken (\(http.statusCode)).")
        }
        withPending { pending in
            for sent in report.events {
                guard let index = pending.events.firstIndex(where: {
                    $0.name == sent.name && $0.props == sent.props && $0.version == sent.version
                }) else { continue }
                pending.events[index].n -= sent.n
            }
            pending.events.removeAll { $0.n <= 0 }
            for sent in report.crashes {
                guard let index = pending.crashes.firstIndex(where: { $0.isSame(as: sent) }) else { continue }
                pending.crashes[index].n -= sent.n
            }
            pending.crashes.removeAll { $0.n <= 0 }
        }
    }
}
