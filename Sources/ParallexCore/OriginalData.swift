import AppKit
import Foundation

/// Starting an own-identity copy from the original app's data: its settings,
/// library and sign-ins (where they live in files), copied into the
/// instance's own home. Copies are APFS clones — instant, and near-free
/// until the two diverge. The original's data is only read.
public enum OriginalData {
    public struct Item: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case folder
            /// The preferences domain (copied through the preferences daemon).
            case preferences(from: String, to: String)
        }

        public let label: String
        public let source: URL
        public let destination: URL
        public let kind: Kind
    }

    /// Dotfolders never copied wholesale: they're shared tool state, or far
    /// more than one app's (and some hold credentials).
    static let sharedDotfolders: Set<String> = [
        "config", "local", "cache", "ssh", "gnupg", "claude", "codex", "aws", "kube", "docker", "npm",
        "cargo", "rustup", "gem", "bundle", "zsh", "oh-my-zsh", "git", "vim", "Trash",
    ]

    /// A name usable as one path component (no separators or "..").
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(":")
    }

    /// What would be copied into this instance (only what exists, and only
    /// into places that belong to the instance alone).
    public static func plan(for manifest: InstanceManifest, realHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Item] {
        guard let home = manifest.redirectedHome, let copyID = manifest.clone?.bundleIdentifier else { return [] }
        let instanceHome = URL(fileURLWithPath: home, isDirectory: true)
        let resolvedHome = instanceHome.resolvingSymlinksInPath().path
        let shared = Set((manifest.homeSymlinks ?? []).map { $0.split(separator: "/").first.map(String.init) ?? $0 })
        let fm = FileManager.default
        let appName = URL(fileURLWithPath: manifest.targetApp).deletingPathExtension().lastPathComponent
        let originalID = manifest.knownTargetBundleID ?? ""
        var names = [appName].filter(isPlainName)
        if let bundleName = NSDictionary(contentsOf: URL(fileURLWithPath: manifest.targetApp)
            .appendingPathComponent("Contents/Info.plist"))?["CFBundleName"] as? String,
           isPlainName(bundleName), !names.contains(bundleName) {
            names.append(bundleName)
        }

        /// Only into the instance's own space: not through (or onto) a link
        /// to your real home — the instance home links shared folders there.
        func isOwnedByInstance(_ relative: String) -> Bool {
            let components = relative.split(separator: "/").map(String.init)
            guard let first = components.first, !shared.contains(first) else { return false }
            var path = instanceHome
            for component in components {
                path = path.appendingPathComponent(component)
                if (try? fm.destinationOfSymbolicLink(atPath: path.path)) != nil {
                    return false
                }
            }
            let parent = path.deletingLastPathComponent().resolvingSymlinksInPath().path
            return parent == resolvedHome || parent.hasPrefix(resolvedHome + "/")
        }

        var items: [Item] = []
        func add(_ relative: String, as destinationRelative: String? = nil, label: String) {
            let source = realHome.appendingPathComponent(relative)
            let destination = destinationRelative ?? relative
            guard fm.fileExists(atPath: source.path),
                  isOwnedByInstance(destination),
                  !items.contains(where: { $0.source.path == source.path })
            else { return }
            items.append(Item(
                label: label,
                source: source,
                destination: instanceHome.appendingPathComponent(destination),
                kind: .folder
            ))
        }

        for folder in Presets.originalDataFolders(bundleID: originalID, names: names) where isPlainName(folder) {
            add("Library/Application Support/\(folder)", label: "Application Support/\(folder)")
        }
        if isPlainName(originalID) {
            // Keyed by bundle ID: the copy looks under its own.
            add("Library/HTTPStorages/\(originalID)", as: "Library/HTTPStorages/\(copyID)", label: "web storage")
            add("Library/HTTPStorages/\(originalID).binarycookies",
                as: "Library/HTTPStorages/\(copyID).binarycookies", label: "cookies")
            add("Library/WebKit/\(originalID)", as: "Library/WebKit/\(copyID)", label: "web content data")
        }
        for name in names {
            let lower = name.lowercased()
            add(".config/\(lower)", label: "~/.config/\(lower)")
            let slug = Slug.make(name)
            if !slug.isEmpty, !sharedDotfolders.contains(slug) {
                add(".\(slug)", label: "~/.\(slug)")
            }
        }
        let preferences = realHome.appendingPathComponent("Library/Preferences/\(originalID).plist")
        if isPlainName(originalID), fm.fileExists(atPath: preferences.path) {
            items.append(Item(
                label: "preferences",
                source: preferences,
                destination: instanceHome.appendingPathComponent("Library/Preferences/\(copyID).plist"),
                kind: .preferences(from: originalID, to: copyID)
            ))
        }
        return items
    }

    /// Copy the original's data into the instance, replacing what the
    /// instance had there (that goes to the Trash). Returns what was copied.
    @discardableResult
    public static func copy(
        into manifest: InstanceManifest,
        realHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> [Item] {
        guard manifest.redirectedHome != nil else {
            let app = URL(fileURLWithPath: manifest.targetApp).deletingPathExtension().lastPathComponent
            throw ParallexError("“\(manifest.name)” uses the real Library, so it already sees \(app)'s data.")
        }
        if Running.isRunning(manifest) {
            throw ParallexError("Quit “\(manifest.name)” first.")
        }
        // A live profile (SQLite with its journal, LevelDB) copies corrupt.
        if let originalID = manifest.knownTargetBundleID, isPlainName(originalID) {
            let running = onMainThreadValue { NSRunningApplication.runningApplications(withBundleIdentifier: originalID).count }
            if running > 0 {
                let app = URL(fileURLWithPath: manifest.targetApp).deletingPathExtension().lastPathComponent
                throw ParallexError("Quit \(app) first, so its data is copied in a consistent state.")
            }
        }
        let items = plan(for: manifest, realHome: realHome)
        guard !items.isEmpty else {
            throw ParallexError("Found nothing of the original app's to copy.")
        }
        let fm = FileManager.default
        for item in items {
            switch item.kind {
            case .folder:
                if fm.fileExists(atPath: item.destination.path) {
                    try fm.trashItem(at: item.destination, resultingItemURL: nil)
                }
                try fm.createDirectory(at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Shell.run("/bin/cp", ["-cRp", item.source.path, item.destination.path])
                InstanceCreator.removeRunState(in: item.destination)
            case .preferences(let from, let to):
                // The copy's own preferences go to the Trash first, like the rest.
                let previous = fm.temporaryDirectory.appendingPathComponent("\(to) (before copying).plist")
                try? fm.removeItem(at: previous)
                if (try? Shell.run("/usr/bin/defaults", ["export", to, previous.path])) != nil {
                    try? fm.trashItem(at: previous, resultingItemURL: nil)
                }
                let exported = fm.temporaryDirectory.appendingPathComponent("parallex-prefs-\(UUID().uuidString).plist")
                defer { try? fm.removeItem(at: exported) }
                try Shell.run("/usr/bin/defaults", ["export", from, exported.path])
                try Shell.run("/usr/bin/defaults", ["import", to, exported.path])
            }
        }
        return items
    }
}
