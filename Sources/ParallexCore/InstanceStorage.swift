import Foundation

/// Disk usage of an instance, and safe ways to get space back.
public struct StorageReport: Sendable {
    public struct Item: Sendable, Identifiable {
        public let url: URL
        public let bytes: Int64
        public var id: String { url.path }
    }

    public let totalBytes: Int64
    /// Chromium/Electron caches inside the instance's data — rebuilt on
    /// demand by the app, safe to clear while it isn't running.
    public let caches: [Item]
    /// Folders Parallex created for an earlier configuration that the
    /// current settings no longer use (e.g. `home/` after switching to a
    /// recipe). Anything Parallex didn't create is never listed — apps and
    /// their tools may keep state next to their data.
    public let unused: [Item]

    public var cacheBytes: Int64 { caches.reduce(0) { $0 + $1.bytes } }
    public var unusedBytes: Int64 { unused.reduce(0) { $0 + $1.bytes } }
}

public enum InstanceStorage {
    /// Cache folders Chromium-based apps recreate on their own.
    static let cacheNames: Set<String> = [
        "Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "GrShaderCache", "ShaderCache", "CachedData",
    ]

    /// Folders Parallex's isolation modes and recipes create. Only these can
    /// ever be reported as unused.
    static let parallexCreatedFolders: Set<String> = [
        "data", "extensions", "profile", "home", "codex-home", "claude-code",
    ]

    public static func report(for manifest: InstanceManifest) -> StorageReport {
        let fm = FileManager.default
        let instanceDir = Paths.instanceDir(slug: manifest.slug)
        let total = allocatedSize(of: instanceDir)

        var caches: [StorageReport.Item] = []
        for root in dataRoots(of: manifest) {
            // Caches sit at the top of the data dir and one level down
            // (inside Chromium profile folders like Default/ or Partitions/*).
            for level1 in children(of: root) {
                if cacheNames.contains(level1.lastPathComponent) {
                    caches.append(.init(url: level1, bytes: allocatedSize(of: level1)))
                    continue
                }
                for level2 in children(of: level1) where cacheNames.contains(level2.lastPathComponent) {
                    caches.append(.init(url: level2, bytes: allocatedSize(of: level2)))
                }
            }
        }

        let used = Set(usedTopLevelNames(of: manifest))
        let unused = children(of: instanceDir)
            .filter { url in
                let name = url.lastPathComponent
                return parallexCreatedFolders.contains(name) && !used.contains(name)
            }
            .map { StorageReport.Item(url: $0, bytes: allocatedSize(of: $0)) }
            .filter { fm.fileExists(atPath: $0.url.path) }

        return StorageReport(
            totalBytes: total,
            caches: caches.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes },
            unused: unused.sorted { $0.bytes > $1.bytes }
        )
    }

    /// Move the given items to the Trash. Refuses while the instance runs
    /// (the app would recreate or corrupt what it has open), and re-derives
    /// the report from the instance's *current* manifest so a stale list
    /// (settings changed since it was measured) can't remove data in use:
    /// only items that are still caches or still unused are accepted.
    @discardableResult
    public static func trash(_ items: [URL], of manifest: InstanceManifest) throws -> Int {
        let current = InstanceStore.load(slug: manifest.slug) ?? manifest
        if Running.isRunning(current) {
            throw ParallexError("Quit “\(current.name)” first — it's using these files.")
        }
        let fresh = report(for: current)
        let removable = Set((fresh.caches + fresh.unused).map { $0.url.standardizedFileURL.path })
        var moved = 0
        for item in items {
            let path = item.standardizedFileURL.path
            guard removable.contains(path) else {
                throw ParallexError(
                    "Refusing to remove \(Paths.abbreviate(path)): it isn't a cache or an unused folder "
                    + "under the instance's current settings."
                )
            }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            try Trash.move(item)
            moved += 1
        }
        return moved
    }

    // MARK: - Helpers

    /// The instance's data directories, as its settings define them now.
    static func dataRoots(of manifest: InstanceManifest) -> [URL] {
        let instanceDir = Paths.instanceDir(slug: manifest.slug)
        return usedTopLevelNames(of: manifest).map { instanceDir.appendingPathComponent($0) }
    }

    /// Top-level names inside the instance directory that the current launch
    /// configuration points at (data/, extensions/, home/, codex-home/, …).
    static func usedTopLevelNames(of manifest: InstanceManifest) -> [String] {
        let instancePath = Paths.instanceDir(slug: manifest.slug).path + "/"
        var paths = manifest.arguments + Array(manifest.environment.values)
        if manifest.mode == .home {
            paths.append(instancePath + "home")
        }
        // A copy's own home (its whole Library), and what short aliases in
        // the arguments stand for (VS Code's data folder).
        if let home = manifest.redirectedHome {
            paths.append(home)
        }
        paths += Array((manifest.links ?? [:]).values)
        var names: [String] = []
        for value in paths {
            guard let range = value.range(of: instancePath) else { continue }
            let rest = value[range.upperBound...]
            if let first = rest.split(separator: "/").first, !names.contains(String(first)) {
                names.append(String(first))
            }
        }
        return names
    }

    static func children(of url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []
        )) ?? []
    }

    /// Bytes actually allocated on disk (sparse files and clones counted
    /// as they are, not by their logical size).
    public static func allocatedSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            if let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    public static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
