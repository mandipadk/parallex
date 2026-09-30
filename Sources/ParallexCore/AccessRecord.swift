import Foundation

/// What a copy's flight recorder noted (see recorder.c in ParallexHome):
/// every file in your home outside the instance that a copy with its own
/// Library opened, created or renamed, once per path per process, and what
/// Guard kept it out of. Read by
/// the isolation check, so a check covers everything since the copy was
/// first opened, not only the files it has open at that moment.
public enum AccessRecord {
    public struct Entry: Sendable, Hashable {
        public let date: Date
        public let pid: Int32
        public let program: String
        /// "read", "write" or "create", or "blocked": Guard refused it.
        public let operation: String
        public let path: String

        public var wasBlocked: Bool { operation == "blocked" }
    }

    /// Current file, then the one it rolled over from (2 MB each).
    static func files(slug: String) -> [URL] {
        let folder = Paths.instanceDir(slug: slug)
        return [folder.appendingPathComponent("access.log.1"), folder.appendingPathComponent("access.log")]
    }

    /// Names that are the record, not the instance's data (left out of
    /// duplicates and exports).
    static let fileNames: Set<String> = ["access.log", "access.log.1"]

    /// Whether this instance has a recorder (a copy with its own Library
    /// that has been opened since 1.2).
    public static func exists(for manifest: InstanceManifest) -> Bool {
        files(slug: manifest.slug).contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func entries(for manifest: InstanceManifest) -> [Entry] {
        var entries: [Entry] = []
        for file in files(slug: manifest.slug) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
                guard fields.count == 5, let seconds = TimeInterval(fields[0]), let pid = Int32(fields[1]) else { continue }
                entries.append(Entry(
                    date: Date(timeIntervalSince1970: seconds), pid: pid, program: String(fields[2]),
                    operation: String(fields[3]), path: String(fields[4])
                ))
            }
        }
        return entries
    }

    /// What Guard refused, each path once, in the order first refused.
    static func blockedPaths(in entries: [Entry]) -> [String] {
        var seen = Set<String>()
        return entries.filter(\.wasBlocked).map(\.path).filter { seen.insert($0).inserted }
    }

    /// When recording began: the copy's first launch with a recorder (the
    /// launcher makes the file), or the oldest note if that's earlier.
    static func since(for manifest: InstanceManifest, entries: [Entry]) -> Date? {
        let made = files(slug: manifest.slug).compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.creationDate] as? Date
        }
        return (made + entries.map(\.date)).min()
    }
}
