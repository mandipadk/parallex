import Foundation

/// Keeps an own-identity copy's home looking like your real one: everything
/// in your home is linked in, except `Library` (the copy's own) and the
/// app's own folders, which the copy keeps to itself. Run at every launch,
/// so what you add to your home appears in the copy and what you remove
/// disappears. Only ever adds or removes its own links; anything the copy
/// created stays untouched.
public enum HomeMirror {
    /// Never linked: the copy's own Library, and what macOS keeps per home.
    static let neverLinked: Set<String> = ["Library", ".Trash", ".DS_Store"]

    /// - Parameter privateItems: relative paths (`.vscode`, `.config/zed`,
    ///   `.local/share/zed`) that stay the copy's own. Folders on the way to
    ///   one become real folders whose other entries are linked.
    public static func sync(home: URL, realHome: URL, privateItems: [String]) {
        var tree = Node()
        for item in privateItems {
            let parts = item.split(separator: "/").map(String.init)
            guard !parts.isEmpty, parts.allSatisfy(isPlainName) else { continue }
            tree.insert(parts[...])
        }
        for name in neverLinked {
            tree.children[name] = Node(isPrivate: true)
        }
        mirror(home, from: realHome, rules: tree)
    }

    /// Which entries under a folder are the copy's own (`isPrivate`), or
    /// hold something that is (`children`).
    struct Node {
        var isPrivate = false
        var children: [String: Node] = [:]

        mutating func insert(_ parts: ArraySlice<String>) {
            guard let first = parts.first else { return }
            if parts.count == 1 {
                children[first] = Node(isPrivate: true)
            } else if children[first]?.isPrivate != true {
                children[first, default: Node()].insert(parts.dropFirst())
            }
        }
    }

    private static func mirror(_ directory: URL, from real: URL, rules: Node) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let realItems = Set((try? fm.contentsOfDirectory(atPath: real.path)) ?? [])

        // First drop links that no longer belong: their target is gone, or
        // the item is now (or holds) the copy's own, which must not be shared.
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] {
            let path = directory.appendingPathComponent(name)
            guard isOwnLink(path, to: real.appendingPathComponent(name)) else { continue }
            if !realItems.contains(name) || rules.children[name] != nil {
                try? fm.removeItem(at: path)
            }
        }

        for name in realItems {
            let path = directory.appendingPathComponent(name)
            let source = real.appendingPathComponent(name)
            if let rule = rules.children[name] {
                if rule.isPrivate { continue }
                // Shared, except for the copy's own entries somewhere inside.
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                if (try? fm.destinationOfSymbolicLink(atPath: path.path)) == nil {
                    var inner = rule
                    inner.children[".DS_Store"] = Node(isPrivate: true)
                    mirror(path, from: source, rules: inner)
                }
                continue
            }
            // Anything already there (the copy's own, or our link) stays.
            guard (try? fm.attributesOfItem(atPath: path.path)) == nil else { continue }
            try? fm.createSymbolicLink(at: path, withDestinationURL: source)
        }
    }

    /// A link this mirror made: pointing at exactly that item of your home.
    private static func isOwnLink(_ path: URL, to source: URL) -> Bool {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path.path) else { return false }
        return destination == source.path
    }

    private static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }
}
