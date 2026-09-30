import Foundation
import ParallexKit

/// Snapshots of an instance's data: its folders, its own keychain and a
/// copy's preferences, as they were at one moment, kept in the instance
/// folder (`snapshots/`). Taking one clones the files (APFS), so it's
/// instant and takes no space until the instance's data moves on from it.
/// Restoring one first takes a snapshot of what's there, so a restore can
/// be undone the same way.
///
/// Only while nothing runs from the instance: an app's files mid-write
/// aren't a moment worth going back to, and it would overwrite a restore
/// with what it holds in memory.
public enum Snapshots {
    public struct Snapshot: Codable, Sendable, Hashable, Identifiable {
        public enum Reason: String, Codable, Sendable {
            /// Taken by you.
            case manual
            /// What the instance had before a restore.
            case beforeRestore = "before-restore"
        }

        /// Its folder's name.
        public let id: String
        public let date: Date
        public var label: String?
        public let reason: Reason
        /// The app's version when it was taken.
        public let appVersion: String?
    }

    public static let folderName = "snapshots"
    static let dataFolder = "data"
    static let recordFile = "snapshot.json"
    static let preferencesFile = "preferences.plist"
    /// How many snapshots taken for you (before a restore) are kept; yours
    /// stay until you delete them.
    static let keptAutomatic = 5

    /// What in the instance folder is bookkeeping, not the instance's data:
    /// never in a snapshot, and left alone by a restore.
    static func isBookkeeping(_ item: String) -> Bool {
        ["instance.json", "instance.pid", "instance.pid.lock", folderName, ParallexConfig.stagingFolder,
         "signin.log", ParallexConfig.separationUnavailableMarker].contains(item)
            || AccessRecord.fileNames.contains(item) || item.hasPrefix("custom-icon.") || item.hasPrefix(".")
    }

    static func folder(slug: String) -> URL {
        Paths.instanceDir(slug: slug).appendingPathComponent(folderName, isDirectory: true)
    }

    /// Newest first.
    public static func list(_ manifest: InstanceManifest) -> [Snapshot] {
        let root = folder(slug: manifest.slug)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .compactMap { name in
                guard let data = try? Data(contentsOf: root.appendingPathComponent(name).appendingPathComponent(recordFile))
                else { return nil }
                return try? decoder.decode(Snapshot.self, from: data)
            }
            .sorted { $0.date > $1.date }
    }

    public static func find(_ id: String, in manifest: InstanceManifest) -> Snapshot? {
        list(manifest).first { $0.id == id }
    }

    /// Why a snapshot can't be taken or restored right now, if it can't.
    public static func unavailableReason(_ manifest: InstanceManifest) -> String? {
        if manifest.clone != nil, Running.anythingRunning(inside: manifest.wrapperPath) {
            return "Quit “\(manifest.name)” first: its files change while it runs."
        }
        if Running.isRunning(manifest) {
            return "Quit “\(manifest.name)” first: its files change while it runs."
        }
        return nil
    }

    @discardableResult
    public static func take(
        _ manifest: InstanceManifest, label: String? = nil, reason: Snapshot.Reason = .manual, now: Date = Date()
    ) throws -> Snapshot {
        let lock = try launchLock(manifest)
        defer { lock.release() }
        if let problem = unavailableReason(manifest) {
            throw ParallexError(problem)
        }
        let snapshot = try capture(manifest, label: label, reason: reason, now: now)
        prune(manifest)
        return snapshot
    }

    /// The lock a copy's launcher holds from "is it running?" until it
    /// becomes the app: held, the instance can't start meanwhile.
    private static func launchLock(_ manifest: InstanceManifest) throws -> FileLock {
        try FileLock(URL(fileURLWithPath: Paths.pidFile(slug: manifest.slug).path + ".lock"))
    }

    private static func capture(
        _ manifest: InstanceManifest, label: String?, reason: Snapshot.Reason, now: Date
    ) throws -> Snapshot {
        let fm = FileManager.default
        let instance = Paths.instanceDir(slug: manifest.slug)
        let root = folder(slug: manifest.slug)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // What a snapshot interrupted before (a crash, say) left half made.
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasPrefix(".") {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
        let id = uniqueID(for: now, in: root)
        let snapshot = Snapshot(
            id: id, date: now, label: label.flatMap { $0.isEmpty ? nil : $0 }, reason: reason,
            appVersion: AppCloner.version(of: URL(fileURLWithPath: manifest.targetApp))
        )
        // Assembled beside the others under a name `list` skips, then
        // named: a half-taken snapshot is never offered.
        let partial = root.appendingPathComponent(".\(id)", isDirectory: true)
        try? fm.removeItem(at: partial)
        let data = partial.appendingPathComponent(dataFolder, isDirectory: true)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        do {
            for item in (try fm.contentsOfDirectory(atPath: instance.path)).sorted() where !isBookkeeping(item) {
                try Shell.run("/bin/cp", ["-cRp", instance.appendingPathComponent(item).path, data.appendingPathComponent(item).path])
            }
            if let copyID = manifest.clone?.bundleIdentifier {
                _ = try? Shell.run("/usr/bin/defaults", ["export", copyID, partial.appendingPathComponent(preferencesFile).path])
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: partial.appendingPathComponent(recordFile))
            try fm.moveItem(at: partial, to: root.appendingPathComponent(id, isDirectory: true))
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return snapshot
    }

    private static func uniqueID(for date: Date, in root: URL) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = formatter.string(from: date)
        var id = base
        var index = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(id).path) {
            id = "\(base)-\(index)"
            index += 1
        }
        return id
    }

    /// Put the instance's data back as it was in `snapshot`. What it had
    /// until now is kept as a snapshot of its own, which is returned. The
    /// instance can't start meanwhile, and if anything fails, it keeps what
    /// it had.
    @discardableResult
    public static func restore(_ snapshot: Snapshot, of manifest: InstanceManifest, now: Date = Date()) throws -> Snapshot {
        let lock = try launchLock(manifest)
        defer { lock.release() }
        if let problem = unavailableReason(manifest) {
            throw ParallexError(problem)
        }
        let fm = FileManager.default
        let source = folder(slug: manifest.slug).appendingPathComponent(snapshot.id, isDirectory: true)
        let data = source.appendingPathComponent(dataFolder, isDirectory: true)
        guard fm.fileExists(atPath: source.appendingPathComponent(recordFile).path),
              let items = try? fm.contentsOfDirectory(atPath: data.path)
        else {
            throw ParallexError("That snapshot of “\(manifest.name)” is gone.")
        }
        let before = try capture(manifest, label: nil, reason: .beforeRestore, now: now)
        let instance = Paths.instanceDir(slug: manifest.slug)
        // The snapshot's data is cloned beside the instance's first; then the
        // two change places by renames, and back if one fails.
        let incoming = instance.appendingPathComponent(".restoring-\(snapshot.id)", isDirectory: true)
        let outgoing = instance.appendingPathComponent(".replaced-\(snapshot.id)", isDirectory: true)
        try? fm.removeItem(at: incoming)
        try? fm.removeItem(at: outgoing)
        defer {
            try? fm.removeItem(at: incoming)
            try? fm.removeItem(at: outgoing)
        }
        try fm.createDirectory(at: incoming, withIntermediateDirectories: false)
        try fm.createDirectory(at: outgoing, withIntermediateDirectories: false)
        let restored = items.filter { !isBookkeeping($0) }
        for item in restored {
            try Shell.run("/bin/cp", ["-cRp", data.appendingPathComponent(item).path, incoming.appendingPathComponent(item).path])
        }
        let current = try fm.contentsOfDirectory(atPath: instance.path).filter { !isBookkeeping($0) }
        var movedOut: [String] = []
        var movedIn: [String] = []
        do {
            for item in current {
                try fm.moveItem(at: instance.appendingPathComponent(item), to: outgoing.appendingPathComponent(item))
                movedOut.append(item)
            }
            for item in restored {
                try fm.moveItem(at: incoming.appendingPathComponent(item), to: instance.appendingPathComponent(item))
                movedIn.append(item)
            }
        } catch {
            for item in movedIn {
                try? fm.moveItem(at: instance.appendingPathComponent(item), to: incoming.appendingPathComponent(item))
            }
            for item in movedOut {
                try? fm.moveItem(at: outgoing.appendingPathComponent(item), to: instance.appendingPathComponent(item))
            }
            throw error
        }
        if let copyID = manifest.clone?.bundleIdentifier {
            // Import adds to what's there: start from nothing, so keys set
            // since the snapshot go too.
            _ = try? Shell.run("/usr/bin/defaults", ["delete", copyID])
            let preferences = source.appendingPathComponent(preferencesFile)
            if fm.fileExists(atPath: preferences.path) {
                _ = try? Shell.run("/usr/bin/defaults", ["import", copyID, preferences.path])
            }
        }
        prune(manifest, keeping: snapshot.id)
        return before
    }

    /// To the Trash, like the rest of an instance's data.
    public static func delete(_ snapshot: Snapshot, of manifest: InstanceManifest) throws {
        let url = folder(slug: manifest.slug).appendingPathComponent(snapshot.id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try Trash.move(url)
    }

    public static func rename(_ snapshot: Snapshot, of manifest: InstanceManifest, to label: String?) throws {
        let url = folder(slug: manifest.slug).appendingPathComponent(snapshot.id).appendingPathComponent(recordFile)
        var renamed = snapshot
        renamed.label = label.flatMap { $0.isEmpty ? nil : $0 }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(renamed).write(to: url, options: .atomic)
    }

    /// Only the newest few taken for you are kept (and never `keeping`,
    /// the one just restored).
    static func prune(_ manifest: InstanceManifest, keeping: String? = nil) {
        let automatic = list(manifest).filter { $0.reason != .manual && $0.id != keeping }
        for snapshot in automatic.dropFirst(keptAutomatic) {
            try? FileManager.default.removeItem(at: folder(slug: manifest.slug).appendingPathComponent(snapshot.id))
        }
    }
}
