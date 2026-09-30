import Foundation

/// Learning from the record: hidden folders in your home that a copy with
/// its own Library writes to through its home's links (so it shares them
/// with the original and everything else), offered to keep to the copy
/// instead. Parallex already keeps the app's own folders private, by name;
/// this finds the ones named otherwise (`~/.config/<vendor>`, say).
public enum PrivateSuggestions {
    public struct Suggestion: Sendable, Hashable, Identifiable {
        /// Relative to your home, as `privateHomeItems` has it (`.config/acme`).
        public let item: String
        public let writes: Int
        public let lastWritten: Date
        public var id: String { item }
    }

    /// Kept in your home for everything on purpose: identity, shells and
    /// caches, which a copy may well write to without them being its own.
    static let neverSuggested: Set<String> = [
        ".ssh", ".gnupg", ".gitconfig", ".git-credentials", ".netrc", ".CFUserTextEncoding", ".DS_Store", ".Trash",
        ".zsh_history", ".zsh_sessions", ".bash_history", ".bash_sessions", ".zshrc", ".bashrc", ".profile",
        ".lesshst", ".viminfo", ".python_history", ".node_repl_history", ".cache", ".npm", ".cups",
    ]

    /// Folders whose entries are each some app's (`.config/acme`).
    static let containers: [[String]] = [[".config"], [".local", "share"], [".local", "state"]]

    public static func suggestions(for manifest: InstanceManifest, home: String? = nil) -> [Suggestion] {
        guard manifest.redirectedHome != nil, manifest.privateHomeItems != nil else { return [] }
        let home = home ?? FileManager.default.homeDirectoryForCurrentUser.path
        let kept = (manifest.privateHomeItems ?? []) + (manifest.homeSymlinks ?? [])
        var found: [String: (writes: Int, last: Date)] = [:]
        for entry in AccessRecord.entries(for: manifest) where entry.operation == "write" || entry.operation == "create" {
            guard let item = item(for: entry.path, home: home),
                  !kept.contains(where: { item == $0 || item.hasPrefix($0 + "/") || $0.hasPrefix(item + "/") })
            else { continue }
            let current = found[item] ?? (0, .distantPast)
            found[item] = (current.writes + 1, max(current.last, entry.date))
        }
        return found.map { Suggestion(item: $0.key, writes: $0.value.writes, lastWritten: $0.value.last) }
            .sorted { ($0.writes, $1.item) > ($1.writes, $0.item) }
    }

    /// The hidden item in your home that `path` belongs to, when it's one
    /// that could be the app's.
    static func item(for path: String, home: String) -> String? {
        guard path.hasPrefix(home + "/") else { return nil }
        let parts = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        guard let first = parts.first, first.hasPrefix("."), !neverSuggested.contains(first) else { return nil }
        for container in containers where parts.count > container.count && Array(parts.prefix(container.count)) == container {
            return (container + [parts[container.count]]).joined(separator: "/")
        }
        return containers.contains([first]) || first == ".local" ? nil : first
    }
}
