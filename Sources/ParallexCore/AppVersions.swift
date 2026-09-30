import Foundation

/// The app versions an own-identity copy can go back to. A copy is built
/// from its app, so Parallex keeps a clone of the app it was built from
/// (`<instance>/versions/`): free while the app in /Applications is the
/// same, and the only copy of that version once the app updates. A copy can
/// then be pinned to a kept version (`InstanceSettings.pinnedVersion`) and
/// built from it instead of the app in /Applications, and the snapshot
/// taken before the refresh (`Snapshots.Snapshot.Reason.beforeRefresh`)
/// puts its data back as that version left it.
public enum AppVersions {
    public struct Kept: Codable, Sendable, Hashable, Identifiable {
        /// As `AppCloner.version(of:)` has it.
        public let version: String
        public let keptAt: Date
        /// The app's file name ("Obsidian.app").
        public let appName: String
        public var id: String { version }
    }

    /// ".noindex": Spotlight leaves it alone, so the kept apps (the vendor's
    /// own, with its bundle ID) aren't offered as the app anywhere.
    public static let folderName = "versions.noindex"
    static let recordFile = "version.json"

    static func folder(slug: String) -> URL {
        Paths.instanceDir(slug: slug).appendingPathComponent(folderName, isDirectory: true)
    }

    /// A folder name for `version` ("1.9.2 (1234)" → "1.9.2-1234").
    static func directoryName(for version: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._"))
        let parts = version.unicodeScalars.split { !allowed.contains($0) }.map { String(String.UnicodeScalarView($0)) }
        return parts.isEmpty ? "unknown" : parts.joined(separator: "-")
    }

    /// Newest first.
    public static func list(slug: String) -> [Kept] {
        let root = folder(slug: slug)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .compactMap { name in
                guard let data = try? Data(contentsOf: root.appendingPathComponent(name).appendingPathComponent(recordFile)),
                      let kept = try? decoder.decode(Kept.self, from: data),
                      FileManager.default.fileExists(atPath: app(of: kept, slug: slug).path)
                else { return nil }
                return kept
            }
            .sorted { $0.keptAt > $1.keptAt }
    }

    public static func list(_ manifest: InstanceManifest) -> [Kept] { list(slug: manifest.slug) }

    public static func app(of kept: Kept, slug: String) -> URL {
        folder(slug: slug).appendingPathComponent(directoryName(for: kept.version), isDirectory: true)
            .appendingPathComponent(kept.appName, isDirectory: true)
    }

    /// The version `input` names among `known`: exactly, or by its short
    /// form ("4.41.105" for "4.41.105 (41105)") when only one has it.
    public static func resolve(_ input: String, among known: [String]) -> String? {
        if known.contains(input) { return input }
        let short = { (version: String) in version.components(separatedBy: " (").first ?? version }
        let matches = Set(known.filter { short($0) == input })
        return matches.count == 1 ? matches.first : nil
    }

    /// Compare two versions as `AppCloner.version(of:)` writes them
    /// ("4.41.106 (41106)"): by the short version, then the build.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func parts(_ version: String) -> (short: String, build: String) {
            let pieces = version.components(separatedBy: " (")
            return (pieces[0], pieces.count > 1 ? String(pieces[1].dropLast()) : "")
        }
        let (left, right) = (parts(lhs), parts(rhs))
        let short = left.short.compare(right.short, options: .numeric)
        return short != .orderedSame ? short : left.build.compare(right.build, options: .numeric)
    }

    /// The kept app of `version`, if there is one.
    public static func app(for version: String, slug: String) -> URL? {
        list(slug: slug).first { $0.version == version }.map { app(of: $0, slug: slug) }
    }

    /// Keep `original` (the app as it is now) if its version isn't kept yet,
    /// then only the `previous` newest other versions. Always kept: `pinned`,
    /// and `leaving`, the version the copy was on (the way back), which
    /// counts as one of the `previous`.
    static func keep(
        original: URL, slug: String, previous: Int, pinned: String?, leaving: String? = nil, now: Date = Date()
    ) {
        let fm = FileManager.default
        let version = AppCloner.version(of: original)
        let root = folder(slug: slug)
        if !list(slug: slug).contains(where: { $0.version == version }) {
            let target = root.appendingPathComponent(directoryName(for: version), isDirectory: true)
            let partial = root.appendingPathComponent(".\(directoryName(for: version))", isDirectory: true)
            try? fm.removeItem(at: partial)
            do {
                try fm.createDirectory(at: partial, withIntermediateDirectories: true)
                // A clone: nothing more on disk until the app in
                // /Applications changes.
                try Shell.run("/bin/cp", ["-cRp", original.path, partial.appendingPathComponent(original.lastPathComponent).path])
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let kept = Kept(version: version, keptAt: now, appName: original.lastPathComponent)
                try encoder.encode(kept).write(to: partial.appendingPathComponent(recordFile))
                try? fm.removeItem(at: target)
                try fm.moveItem(at: partial, to: target)
            } catch {
                try? fm.removeItem(at: partial)
            }
        }
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasPrefix(".") {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
        let back = leaving.flatMap { $0 != version && !$0.isEmpty ? $0 : nil }
        let others = list(slug: slug).filter { $0.version != version && $0.version != pinned && $0.version != back }
        let room = max(0, previous - (back != nil && list(slug: slug).contains { $0.version == back } ? 1 : 0))
        for old in others.dropFirst(room) {
            try? fm.removeItem(at: root.appendingPathComponent(directoryName(for: old.version)))
        }
    }

    /// To the Trash. Not the version the copy is pinned to.
    public static func remove(_ kept: Kept, of manifest: InstanceManifest) throws {
        if manifest.effectiveSettings.pinnedVersion == kept.version {
            throw ParallexError("“\(manifest.name)” is using \(kept.version). Use the current version again first.")
        }
        let url = folder(slug: manifest.slug).appendingPathComponent(directoryName(for: kept.version))
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try Trash.move(url)
    }

    /// Build the copy from the kept `version` from now on (the app in
    /// /Applications again, when that's its version). With `restoreData`,
    /// its data goes back to how that version left it, when a snapshot of
    /// that is kept. Returns the copy as it now is.
    @discardableResult
    public static func use(
        _ version: String, for manifest: InstanceManifest, restoreData: Bool = false,
        builderOptions: BundleBuilder.Options = BundleBuilder.Options()
    ) throws -> InstanceManifest {
        guard manifest.clone != nil else {
            throw ParallexError("“\(manifest.name)” isn't an own-identity copy, so it runs the app as it is.")
        }
        let current = AppCloner.version(of: URL(fileURLWithPath: manifest.targetApp))
        guard let version = resolve(version, among: list(manifest).map(\.version) + [current]) else {
            throw ParallexError("\(version) of “\(manifest.name)”'s app isn't kept. See: parallex versions \"\(manifest.name)\"")
        }
        if version == manifest.clone?.sourceVersion, restoreData {
            throw ParallexError("“\(manifest.name)” is on \(version) already. To put its data back, restore a snapshot.")
        }
        var settings = manifest.effectiveSettings
        if version == current {
            settings.pinnedVersion = nil
        } else {
            guard app(for: version, slug: manifest.slug) != nil else {
                throw ParallexError("\(version) of “\(manifest.name)”'s app isn't kept.")
            }
            settings.pinnedVersion = version
        }
        let snapshot = restoreData ? snapshotBefore(leaving: version, of: manifest) : nil
        if restoreData, snapshot == nil {
            throw ParallexError("No snapshot of how \(version) left “\(manifest.name)”'s data is kept.")
        }
        var result = try InstanceCreator.update(
            manifest, InstanceUpdate(settings: settings), builderOptions: builderOptions, keepingSnapshot: snapshot?.id
        ).manifest
        if let snapshot {
            try Snapshots.restore(snapshot, of: result)
            result = InstanceStore.load(slug: result.slug) ?? result
        }
        return result
    }

    /// The snapshot taken just before the copy moved on from `version`: its
    /// data as that version left it.
    public static func snapshotBefore(leaving version: String, of manifest: InstanceManifest) -> Snapshots.Snapshot? {
        Snapshots.list(manifest).first { $0.reason == .beforeRefresh && $0.appVersion == version }
    }
}
