import Foundation

/// App knowledge that arrives without a Parallex release: the `knowledge`
/// in the signed notices file (`Advisories`), kept on this Mac once
/// verified. It only adds to what's built in (`Presets`): more data folders
/// for the isolation check and Guard, more hidden folders to keep private,
/// more single-instance ports. It's data, never code, and signed with the
/// release key like updates.
public enum Knowledge {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (stamp: Date?, entries: [Advisories.AppKnowledge])?
    /// For tests: used instead of the kept file.
    nonisolated(unsafe) static var override: [Advisories.AppKnowledge]?

    /// What's known about `bundleID` (at `version`, when given).
    public static func entries(for bundleID: String, version: String? = nil) -> [Advisories.AppKnowledge] {
        all().filter { $0.bundleID == bundleID && (version == nil || VersionRange.contains($0.versions, version)) }
    }

    static func all() -> [Advisories.AppKnowledge] {
        lock.lock()
        defer { lock.unlock() }
        if let override { return override }
        // Read (and verified) again only when the kept file changes.
        let stamp = (try? FileManager.default.attributesOfItem(atPath: Advisories.cacheURL.path))?[.modificationDate] as? Date
        if let cache, cache.stamp == stamp { return cache.entries }
        let entries = Advisories.cached()?.knowledge ?? []
        cache = (stamp, entries)
        return entries
    }

    static func dataFolders(for bundleID: String) -> [String] {
        entries(for: bundleID).flatMap { $0.dataFolders ?? [] }.filter(OriginalData.isPlainName)
    }

    static func homeFolders(for bundleID: String) -> [String] {
        entries(for: bundleID).flatMap { $0.homeFolders ?? [] }.filter { item in
            let parts = item.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            return !parts.isEmpty && parts[0].hasPrefix(".") && parts.allSatisfy(OriginalData.isPlainName)
        }
    }

    static func singleInstancePorts(for bundleID: String) -> [(base: Int, plusUserID: Bool)] {
        entries(for: bundleID).flatMap { $0.singleInstancePorts ?? [] }
            .filter { (1024..<65536).contains($0.base) }
            .map { ($0.base, $0.plusUserID ?? false) }
    }
}
