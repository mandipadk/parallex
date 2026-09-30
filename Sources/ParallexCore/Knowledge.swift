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

    /// What's known about `bundleID` at `version` (entries for certain
    /// versions only apply when the version is known and in range).
    public static func entries(for bundleID: String, version: String? = nil) -> [Advisories.AppKnowledge] {
        all().filter { $0.bundleID == bundleID && VersionRange.contains($0.versions, version) }
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

    /// At most this many of each kind per entry.
    static let maxFolders = 32
    static let maxPorts = 16

    /// Never an app's data: Parallex's own folder, and macOS's.
    static func isAllowedDataFolder(_ name: String) -> Bool {
        let lower = name.lowercased()
        return OriginalData.isPlainName(name) && !lower.hasPrefix("com.apple.")
            && !["parallex", "clouddocs", "mobilesync", "addressbook", "icloud", "knowledge"].contains(lower)
    }

    /// A hidden item that can be one app's: never one everything shares
    /// (.ssh, .aws, .config itself, …); under .config at least one folder
    /// down, under .local or .cache two.
    static func isAllowedHomeFolder(_ item: String) -> Bool {
        let parts = item.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, first.hasPrefix("."), parts.allSatisfy(OriginalData.isPlainName) else { return false }
        let name = String(first.dropFirst()).lowercased()
        if Presets.defaultSharedItems.contains(where: { $0.lowercased() == item.lowercased() }) { return false }
        // Shells' and tools' own files, and the folders a persona keeps.
        let sharedFiles: Set<String> = ["zshrc", "zprofile", "zshenv", "zlogin", "bashrc", "bash_profile", "profile",
                                        "npmrc", "netrc", "yarnrc", "yarnrc.yml", "gitconfig", "git-credentials", "inputrc"]
        if sharedFiles.contains(name) { return false }
        if name == "config", parts.count >= 2, ["git", "gh", "gcloud", "hub"].contains(parts[1].lowercased()) { return false }
        switch name {
        case "config": return parts.count >= 2
        case "local", "cache": return parts.count >= 3
        default: return !OriginalData.sharedDotfolders.contains { $0.lowercased() == name }
        }
    }

    static func dataFolders(for bundleID: String, version: String?) -> [String] {
        entries(for: bundleID, version: version).flatMap { Array(($0.dataFolders ?? []).prefix(maxFolders)) }
            .filter(isAllowedDataFolder)
    }

    static func homeFolders(for bundleID: String, version: String?) -> [String] {
        entries(for: bundleID, version: version).flatMap { Array(($0.homeFolders ?? []).prefix(maxFolders)) }
            .filter(isAllowedHomeFolder)
    }

    static func singleInstancePorts(for bundleID: String, version: String?) -> [(base: Int, plusUserID: Bool)] {
        entries(for: bundleID, version: version).flatMap { Array(($0.singleInstancePorts ?? []).prefix(maxPorts)) }
            .filter { (1024...65000).contains($0.base) }
            .map { ($0.base, $0.plusUserID ?? false) }
    }
}
