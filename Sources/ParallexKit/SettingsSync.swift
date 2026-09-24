import Foundation

/// Part of an app's settings shared with the original: before each launch,
/// chosen top-level keys of a JSON settings file are copied from the
/// original's file into the instance's (added, replaced, or removed when the
/// original has none), and the rest of the instance's file is left as it is.
///
/// A file is shared this way, not linked: apps rewrite their settings by
/// saving a new file over the old one, which would quietly replace a link,
/// and the same file usually holds things that should stay apart (Claude's
/// config holds both its MCP servers and its own preferences).
public enum SettingsSync {
    public struct Item: Hashable, Sendable {
        /// The original's file.
        public var from: String
        /// The instance's file.
        public var to: String
        public var keys: [String]

        public init(from: String, to: String, keys: [String]) {
            self.from = from
            self.to = to
            self.keys = keys
        }

        public var plist: [String: Any] {
            ["From": from, "To": to, "Keys": keys]
        }

        public init?(plist: Any) {
            guard let dict = plist as? [String: Any], let from = dict["From"] as? String,
                  let to = dict["To"] as? String, let keys = dict["Keys"] as? [String]
            else { return nil }
            self.init(from: from, to: to, keys: keys)
        }
    }

    public struct Unreadable: Error, CustomStringConvertible {
        public let path: String
        public var description: String { "\(path) isn't a JSON settings file Parallex can read" }
    }

    /// What was last shared into an instance's file, kept beside it: a
    /// value there that differs from this was changed in the instance
    /// (Claude's Developer › Edit Config opens that very file), so it's
    /// kept in a dated backup before being replaced.
    public static let sharedSuffix = ".parallex-shared"
    public static let backupSuffix = ".before-parallex-sharing"

    /// Bring the instance's file in line; true when it changed. Throws,
    /// changing nothing, when either file isn't a JSON object. Nothing
    /// happens while the original's file is missing or empty (not set up,
    /// or caught mid-save): only a file that says so removes a setting.
    @discardableResult
    public static func apply(_ item: Item, now: Date = Date()) throws -> Bool {
        let fm = FileManager.default
        guard let source = try object(at: item.from) else { return false }
        // A settings file that's a link is written through, not replaced.
        let destination = URL(fileURLWithPath: item.to).resolvingSymlinksInPath()
        let current = try object(at: destination.path)
        let sharedFile = destination.path + sharedSuffix
        let lastShared = (try? object(at: sharedFile)) ?? nil
        var target = current ?? [:]
        var changed = false
        var editedHere = false
        for key in item.keys where !same(source[key], target[key]) {
            if target[key] != nil, !same(target[key], lastShared?[key]) { editedHere = true }
            target[key] = source[key]
            changed = true
        }
        guard changed else { return false }

        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if editedHere, fm.fileExists(atPath: destination.path) {
            let stamp = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate, .withTime])
            try? fm.copyItem(atPath: destination.path, toPath: destination.path + backupSuffix + "-" + stamp)
        }
        let data = try JSONSerialization.data(withJSONObject: target, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: destination, options: .atomic)
        var shared: [String: Any] = [:]
        for key in item.keys { shared[key] = source[key] }
        if let record = try? JSONSerialization.data(withJSONObject: shared, options: [.sortedKeys]) {
            try? record.write(to: URL(fileURLWithPath: sharedFile), options: .atomic)
        }
        return true
    }

    /// The file as a JSON object; nil when there's no file (or it's empty).
    static func object(at path: String) throws -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path),
              !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 })
        else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Unreadable(path: path)
        }
        return object
    }

    static func same(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case let (lhs?, rhs?):
            let options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]
            return (try? JSONSerialization.data(withJSONObject: lhs, options: options))
                == (try? JSONSerialization.data(withJSONObject: rhs, options: options))
        }
    }
}
