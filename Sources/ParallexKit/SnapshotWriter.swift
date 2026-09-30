import Foundation

/// Writing a snapshot of an instance's data (see `Snapshots` in
/// ParallexCore, which lists, restores and prunes them). Here so a copy's
/// launcher can take one too, when it puts a refresh of the copy in place
/// that moves it to another version of its app.
public enum SnapshotWriter {
    public static let folderName = "snapshots"
    public static let recordFile = "snapshot.json"
    public static let dataFolder = "data"
    public static let preferencesFile = "preferences.plist"

    /// What in an instance folder is bookkeeping, not the instance's data:
    /// never in a snapshot, and left alone by a restore.
    public static let bookkeepingNames: Set<String> = [
        "instance.json", "instance.pid", "instance.pid.lock", folderName, ParallexConfig.stagingFolder,
        "signin.log", ParallexConfig.separationUnavailableMarker, "versions.noindex", "persona.json",
        "access.log", "access.log.1", "guard.log",
    ]

    public static func isBookkeeping(_ item: String) -> Bool {
        bookkeepingNames.contains(item) || item.hasPrefix("custom-icon.") || item.hasPrefix(".")
    }

    /// A folder name for a snapshot taken at `date`, unique in `root`.
    public static func uniqueID(for date: Date, in root: URL) -> String {
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

    /// Clone `instance`'s data into `<instance>/snapshots/<id>` with
    /// `record` as its snapshot.json, and a copy's preferences (`copyID`).
    /// Assembled under a hidden name and then named, so a half-taken
    /// snapshot is never offered.
    public static func capture(instance: URL, id: String, record: Data, copyID: String?) throws {
        let fm = FileManager.default
        let root = instance.appendingPathComponent(folderName, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasPrefix(".") {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
        let partial = root.appendingPathComponent(".\(id)", isDirectory: true)
        let data = partial.appendingPathComponent(dataFolder, isDirectory: true)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        do {
            for item in (try fm.contentsOfDirectory(atPath: instance.path)).sorted() where !isBookkeeping(item) {
                try run("/bin/cp", ["-cRp", instance.appendingPathComponent(item).path, data.appendingPathComponent(item).path])
            }
            if let copyID {
                try? run("/usr/bin/defaults", ["export", copyID, partial.appendingPathComponent(preferencesFile).path])
            }
            try record.write(to: partial.appendingPathComponent(recordFile))
            try fm.moveItem(at: partial, to: root.appendingPathComponent(id, isDirectory: true))
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "SnapshotWriter", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(tool) failed (\(process.terminationStatus))"])
        }
    }
}
