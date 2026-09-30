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
            /// What a copy had before it moved to another version of its
            /// app (see `AppVersions`).
            case beforeRefresh = "before-refresh"
            /// One a day, with daily snapshots on.
            case daily
        }

        /// Its folder's name.
        public let id: String
        public let date: Date
        public var label: String?
        public let reason: Reason
        /// The app's version when it was taken.
        public let appVersion: String?
    }

    public static let folderName = SnapshotWriter.folderName
    static let dataFolder = SnapshotWriter.dataFolder
    static let recordFile = SnapshotWriter.recordFile
    static let preferencesFile = SnapshotWriter.preferencesFile
    /// How many snapshots taken for you (before a restore) are kept; yours
    /// stay until you delete them.
    static let keptAutomatic = 5

    /// What in the instance folder is bookkeeping, not the instance's data:
    /// never in a snapshot, and left alone by a restore.
    static func isBookkeeping(_ item: String) -> Bool {
        SnapshotWriter.isBookkeeping(item)
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
        _ manifest: InstanceManifest, label: String? = nil, reason: Snapshot.Reason = .manual, now: Date = Date(),
        keeping: String? = nil
    ) throws -> Snapshot {
        guard let snapshot = try takeIf(manifest, label: label, reason: reason, now: now, keeping: keeping, { true }) else {
            throw ParallexError("The snapshot of “\(manifest.name)” wasn't taken.")
        }
        return snapshot
    }

    /// `take`, when `stillWanted` says so under the instance's lock.
    static func takeIf(
        _ manifest: InstanceManifest, label: String? = nil, reason: Snapshot.Reason, now: Date = Date(),
        keeping: String? = nil, _ stillWanted: () -> Bool
    ) throws -> Snapshot? {
        let lock = try launchLock(manifest)
        defer { lock.release() }
        if let problem = unavailableReason(manifest) {
            throw ParallexError(problem)
        }
        // Asked again under the lock (another may have just taken one).
        guard stillWanted() else { return nil }
        let snapshot = try capture(manifest, label: label, reason: reason, now: now)
        prune(manifest, keeping: keeping)
        return snapshot
    }

    /// How many daily snapshots are kept.
    static let keptDaily = 7

    /// With daily snapshots on and none in the last day (give or take),
    /// take one, unless it's running. Returns it, if one was taken.
    @discardableResult
    public static func takeDailyIfDue(_ manifest: InstanceManifest, now: Date = Date()) -> Snapshot? {
        guard manifest.effectiveSettings.dailySnapshots == true, unavailableReason(manifest) == nil else { return nil }
        let due = {
            guard let last = list(manifest).first(where: { $0.reason == .daily }) else { return true }
            return now.timeIntervalSince(last.date) >= 20 * 3600
        }
        guard due() else { return nil }
        return (try? takeIf(manifest, reason: .daily, now: now, due)) ?? nil
    }

    /// For callers already holding the instance's launch lock.
    @discardableResult
    static func takeWhileLocked(
        _ manifest: InstanceManifest, label: String?, reason: Snapshot.Reason, now: Date = Date()
    ) throws -> Snapshot {
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
        let instance = Paths.instanceDir(slug: manifest.slug)
        let root = folder(slug: manifest.slug)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let snapshot = Snapshot(
            id: SnapshotWriter.uniqueID(for: now, in: root), date: now, label: label.flatMap { $0.isEmpty ? nil : $0 },
            reason: reason,
            // The version whose data this is: a copy's own, not the app's
            // in /Applications, which may have moved on already.
            appVersion: manifest.clone?.sourceVersion ?? AppCloner.version(of: URL(fileURLWithPath: manifest.targetApp))
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try SnapshotWriter.capture(
            instance: instance, id: snapshot.id, record: try encoder.encode(snapshot),
            copyID: manifest.clone?.bundleIdentifier
        )
        return snapshot
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
        // Left by a restore that couldn't finish: it may hold data.
        if let leftover = (try? fm.contentsOfDirectory(atPath: instance.path))?.first(where: { $0.hasPrefix(".replaced-") }) {
            throw ParallexError("An earlier restore of “\(manifest.name)” didn't finish. Show its data folder and look in \(leftover) before restoring again.")
        }
        // What was set aside goes only once it's no longer needed: after a
        // swap, or a clean way back.
        var setAsideNeeded = false
        defer {
            try? fm.removeItem(at: incoming)
            if !setAsideNeeded {
                try? fm.removeItem(at: outgoing)
            }
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
                do {
                    try fm.moveItem(at: outgoing.appendingPathComponent(item), to: instance.appendingPathComponent(item))
                } catch {
                    setAsideNeeded = true
                }
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

    /// Only the newest few taken for you are kept, each kind on its own:
    /// the ones kept before restores, and the newest one kept before
    /// leaving each version (up to `keptAutomatic` versions). Never
    /// `keeping`, the one being restored.
    static func prune(_ manifest: InstanceManifest, keeping: String? = nil) {
        let all = list(manifest).filter { $0.id != keeping }
        var doomed = Array(all.filter { $0.reason == .beforeRestore }.dropFirst(keptAutomatic))
        doomed += all.filter { $0.reason == .daily }.dropFirst(keptDaily)
        var versions = Set<String>()
        for snapshot in all where snapshot.reason == .beforeRefresh {
            let version = snapshot.appVersion ?? ""
            if versions.contains(version) || versions.count >= keptAutomatic {
                doomed.append(snapshot)
            } else {
                versions.insert(version)
            }
        }
        for snapshot in doomed {
            try? FileManager.default.removeItem(at: folder(slug: manifest.slug).appendingPathComponent(snapshot.id))
        }
    }
}
