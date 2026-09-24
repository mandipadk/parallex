import Foundation

/// Apps whose instances have passed an isolation check on this Mac, per app
/// version: what lets the catalog say "Verified here" instead of guessing.
/// A check that finds a leak takes the app back off the list.
public enum Verification {
    public struct Record: Codable, Sendable, Equatable {
        /// The app's version when its instance was checked.
        public var version: String?
        public var date: Date
        /// Whether it was an own-identity copy (or a wrapper) that passed.
        public var copy: Bool?
    }

    static var fileURL: URL {
        Paths.supportRoot.appendingPathComponent("verified.json")
    }

    public static func load() -> [String: Record] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Record].self, from: data)) ?? [:]
    }

    private static func save(_ records: [String: Record]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Note what a check of a running instance found. Only a check that saw
    /// the instance actually using its own files counts as verifying it.
    static func record(_ manifest: InstanceManifest, report: IsolationReport, at date: Date = Date()) {
        guard let bundleID = manifest.knownTargetBundleID else { return }
        var records = load()
        if !report.isClean {
            guard records.removeValue(forKey: bundleID) != nil else { return }
        } else if !report.findings(in: .isolated).isEmpty, let kind = defaultKind(of: manifest) {
            // A copy runs the version it was made from, not today's app.
            let version = manifest.clone?.sourceVersion ?? AppCloner.version(of: URL(fileURLWithPath: manifest.targetApp))
            records[bundleID] = Record(version: version, date: date, copy: kind)
        } else {
            return
        }
        save(records)
    }

    /// Only an instance set up the way Parallex recommends vouches for the
    /// app: a copy with its data separate (true), or a wrapper that
    /// actually isolates (false). Anything turned off proves nothing.
    static func defaultKind(of manifest: InstanceManifest) -> Bool? {
        let settings = manifest.effectiveSettings
        if manifest.clone != nil {
            guard settings.separateLibrary != false, settings.separateHiddenFolders != false,
                  manifest.redirectedHome != nil || manifest.separatedGroups != nil || manifest.clone?.usesLauncher == false
            else { return nil }
            return true
        }
        return manifest.mode == .launchOnly ? nil : false
    }

    /// Whether an instance of this app, at this version, has passed a check here.
    public static func isVerified(
        bundleID: String, version: String?, asCopy: Bool, records: [String: Record] = load()
    ) -> Bool {
        guard let record = records[bundleID], record.copy == nil || record.copy == asCopy else { return false }
        return record.version == nil || record.version == version
    }
}
