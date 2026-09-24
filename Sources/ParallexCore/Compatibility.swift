import Foundation

/// What Parallex has learned on this Mac about apps that don't run as
/// own-identity copies — some App Store apps check their purchase receipt,
/// others refuse a changed signature, and either quits right after opening.
/// The catalog uses it to warn before another copy is made.
public enum Compatibility {
    public struct Record: Codable, Sendable, Equatable {
        /// Copies of this app that quit within seconds of opening.
        public var quickExits: Int
        public var lastQuickExit: Date
        /// The app's version when it last happened (a new version may behave).
        public var version: String?
    }

    /// A copy that quits within this long after opening counts as refused.
    public static let quickExitWindow: TimeInterval = 5

    static var fileURL: URL {
        Paths.supportRoot.appendingPathComponent("compatibility.json")
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

    /// A copy of `bundleID` quit right after it opened.
    public static func recordQuickExit(bundleID: String, version: String?, at date: Date = Date()) {
        var records = load()
        var record = records[bundleID] ?? Record(quickExits: 0, lastQuickExit: date, version: version)
        // A newer version starts over.
        if record.version != version {
            record.quickExits = 0
        }
        record.quickExits += 1
        record.lastQuickExit = date
        record.version = version
        records[bundleID] = record
        save(records)
    }

    /// A copy ran fine: forget earlier trouble.
    public static func recordHealthyRun(bundleID: String) {
        var records = load()
        guard records.removeValue(forKey: bundleID) != nil else { return }
        save(records)
    }

    /// Whether copies of this app (at this version) are known to quit.
    public static func refusesCopies(bundleID: String, version: String?, records: [String: Record] = load()) -> Bool {
        guard let record = records[bundleID] else { return false }
        return record.quickExits > 0 && (record.version == nil || record.version == version)
    }
}
