import Foundation
import ParallexKit

/// Isolation mode of a created instance (the `auto` of `--mode auto` is
/// resolved before anything is stored).
public enum InstanceMode: String, Codable, Sendable {
    case dataDir = "data-dir"
    case home
    case launchOnly = "launch-only"

    public var summary: String {
        switch self {
        case .dataDir: "app-aware isolation (data-dir flags)"
        case .home: "HOME override (generic isolation)"
        case .launchOnly: "separate identity only — no data isolation"
        }
    }
}

/// Everything we know about a created instance. Stored as pretty JSON at
/// `<instance dir>/instance.json`, co-located with the instance's data so
/// removing the directory removes every trace.
public struct InstanceManifest: Codable, Sendable {
    public var schemaVersion: Int = 1
    public var name: String
    public var slug: String
    public var bundleIdentifier: String
    public var targetApp: String
    public var targetBinary: String
    public var wrapperPath: String
    public var mode: InstanceMode
    public var preset: String?
    public var arguments: [String]
    public var environment: [String: String]
    public var homeSymlinks: [String]?
    public var createdAt: Date
    public var parallexVersion: String

    init(
        name: String,
        slug: String,
        bundleIdentifier: String,
        targetApp: String,
        targetBinary: String,
        wrapperPath: String,
        mode: InstanceMode,
        preset: String?,
        arguments: [String],
        environment: [String: String],
        homeSymlinks: [String]?,
        createdAt: Date,
        parallexVersion: String
    ) {
        self.name = name
        self.slug = slug
        self.bundleIdentifier = bundleIdentifier
        self.targetApp = targetApp
        self.targetBinary = targetBinary
        self.wrapperPath = wrapperPath
        self.mode = mode
        self.preset = preset
        self.arguments = arguments
        self.environment = environment
        self.homeSymlinks = homeSymlinks
        self.createdAt = createdAt
        self.parallexVersion = parallexVersion
    }
}

public enum InstanceStore {
    public static let manifestFilename = "instance.json"

    public static func manifestURL(slug: String) -> URL {
        Paths.instanceDir(slug: slug).appendingPathComponent(manifestFilename)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func save(_ manifest: InstanceManifest) throws {
        let url = manifestURL(slug: manifest.slug)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    public static func load(slug: String) -> InstanceManifest? {
        guard let data = try? Data(contentsOf: manifestURL(slug: slug)) else {
            return nil
        }
        return try? decoder.decode(InstanceManifest.self, from: data)
    }

    /// All known instances, sorted by name. Corrupt manifests are reported on
    /// stderr and skipped rather than failing the whole listing.
    public static func loadAll() -> [InstanceManifest] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Paths.instancesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else {
            return []
        }
        var manifests: [InstanceManifest] = []
        for entry in entries {
            let manifestFile = entry.appendingPathComponent(manifestFilename)
            guard fm.fileExists(atPath: manifestFile.path) else { continue }
            do {
                let data = try Data(contentsOf: manifestFile)
                manifests.append(try decoder.decode(InstanceManifest.self, from: data))
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: skipping unreadable manifest \(manifestFile.path): \(error)\n".utf8
                ))
            }
        }
        return manifests.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Look an instance up by display name (case-insensitive) or slug.
    public static func find(_ nameOrSlug: String) -> InstanceManifest? {
        if let bySlug = load(slug: nameOrSlug) {
            return bySlug
        }
        let slugified = Slug.make(nameOrSlug)
        if !slugified.isEmpty, let manifest = load(slug: slugified) {
            return manifest
        }
        return loadAll().first { $0.name.caseInsensitiveCompare(nameOrSlug) == .orderedSame }
    }
}
