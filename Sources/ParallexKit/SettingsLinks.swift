import Foundation

/// The links an editor copy's home keeps to your settings while they're
/// shared (see SharedSettings in ParallexCore), made and undone by the
/// copy's launcher. The copy's own version waits beside a link, and comes
/// back when sharing stops. Nothing of yours is ever moved or changed.
public enum SettingsLinks {
    /// In the instance folder: what the launcher linked last time.
    public static let markerFile = "shared-settings.json"
    public static let ownSuffix = ".parallex-own"

    /// Whether a folder on the way to `item` in `home` is a link (into your
    /// home, through the mirror): then the item there is yours, already
    /// shared, and nothing is to be moved or linked.
    static func throughLink(_ item: String, home: URL) -> Bool {
        var path = home
        let parts = item.split(separator: "/").map(String.init)
        for part in parts.dropLast() {
            path = path.appendingPathComponent(part)
            var info = stat()
            if lstat(path.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                return true
            }
        }
        return false
    }

    public static func link(_ item: String, home: URL, realHome: URL) {
        let fm = FileManager.default
        let real = realHome.appendingPathComponent(item)
        let own = home.appendingPathComponent(item)
        guard fm.fileExists(atPath: real.path), !item.contains(".."), !throughLink(item, home: home) else { return }
        if let destination = try? fm.destinationOfSymbolicLink(atPath: own.path) {
            // Ours already, or someone else's link: left as it is.
            _ = destination
            return
        }
        if fm.fileExists(atPath: own.path) {
            let aside = own.deletingLastPathComponent().appendingPathComponent(own.lastPathComponent + ownSuffix)
            guard !fm.fileExists(atPath: aside.path), (try? fm.moveItem(at: own, to: aside)) != nil else { return }
        }
        try? fm.createDirectory(at: own.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: own, withDestinationURL: real)
    }

    public static func unlink(_ item: String, home: URL, realHome: URL) {
        let fm = FileManager.default
        let own = home.appendingPathComponent(item)
        guard !item.contains(".."), !throughLink(item, home: home), let destination = try? fm.destinationOfSymbolicLink(atPath: own.path),
              destination == realHome.appendingPathComponent(item).path
        else { return }
        try? fm.removeItem(at: own)
        let aside = own.deletingLastPathComponent().appendingPathComponent(own.lastPathComponent + ownSuffix)
        if fm.fileExists(atPath: aside.path) {
            try? fm.moveItem(at: aside, to: own)
        }
    }

    /// Link `items`, and undo what was linked before but isn't anymore.
    public static func sync(_ items: [String], home: URL, realHome: URL, instance: URL) {
        let marker = instance.appendingPathComponent(markerFile)
        let before = (try? Data(contentsOf: marker)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        for item in before where !items.contains(item) {
            unlink(item, home: home, realHome: realHome)
        }
        for item in items {
            link(item, home: home, realHome: realHome)
        }
        if items.isEmpty {
            try? FileManager.default.removeItem(at: marker)
        } else if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: marker, options: .atomic)
        }
    }
}
