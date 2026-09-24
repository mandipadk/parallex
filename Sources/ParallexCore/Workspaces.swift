import AppKit
import Foundation

/// A named set of instances that open together — "Work", "Personal" — with
/// an optional shortcut. Stored in Parallex's support folder, shared by the
/// app and the CLI.
public struct Workspace: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    /// Instance slugs, in the order they open.
    public var members: [String]
    public var shortcut: KeyShortcut?
    /// Opening the workspace hides running instances that aren't in it.
    public var hidesOthers: Bool

    public init(id: UUID = UUID(), name: String, members: [String] = [], shortcut: KeyShortcut? = nil, hidesOthers: Bool = false) {
        self.id = id
        self.name = name
        self.members = members
        self.shortcut = shortcut
        self.hidesOthers = hidesOthers
    }

    /// Its members that still exist, as manifests, in order.
    public func instances(in manifests: [InstanceManifest]) -> [InstanceManifest] {
        let bySlug = Dictionary(manifests.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        return members.compactMap { bySlug[$0] }
    }
}

public enum WorkspaceStore {
    static var fileURL: URL {
        Paths.supportRoot.appendingPathComponent("workspaces.json")
    }

    private struct File: Codable {
        var version = 1
        var workspaces: [Workspace]
    }

    public static func load() -> [Workspace] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode(File.self, from: data).workspaces
        } catch {
            FileHandle.standardError.write(Data("warning: skipping unreadable \(fileURL.path): \(error)\n".utf8))
            return []
        }
    }

    public static func save(_ workspaces: [Workspace]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(workspaces: workspaces)).write(to: fileURL, options: .atomic)
    }

    /// Read, change and write the workspaces under a lock, so the app and
    /// the CLI can't overwrite each other's edits. Its own lock, not the
    /// creation lock: the app edits workspaces on the main thread, and a
    /// create holding the creation lock may be waiting on the main thread.
    @discardableResult
    public static func modify<T>(_ change: (inout [Workspace]) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = try FileLock(fileURL.deletingLastPathComponent().appendingPathComponent(".workspaces.lock"))
        defer { lock.release() }
        // An unreadable file is kept aside rather than overwritten.
        if let data = try? Data(contentsOf: fileURL), (try? JSONDecoder().decode(File.self, from: data)) == nil {
            let aside = fileURL.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
        }
        var workspaces = load()
        let result = try change(&workspaces)
        try save(workspaces)
        return result
    }

    /// Find by name (case-insensitive) or id.
    public static func find(_ nameOrID: String, in workspaces: [Workspace] = load()) -> Workspace? {
        workspaces.first { $0.name.caseInsensitiveCompare(nameOrID) == .orderedSame }
            ?? workspaces.first { $0.id.uuidString.caseInsensitiveCompare(nameOrID) == .orderedSame }
    }

    /// Create a workspace; names are unique (ignoring case).
    @discardableResult
    public static func create(name: String, members: [String] = []) throws -> Workspace {
        let trimmed = name.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !trimmed.isEmpty else { throw ParallexError("A workspace needs a name.") }
        return try modify { workspaces in
            guard find(trimmed, in: workspaces) == nil else {
                throw ParallexError("There's already a workspace named “\(trimmed)”.")
            }
            var unique: [String] = []
            for slug in members where !unique.contains(slug) {
                unique.append(slug)
            }
            let workspace = Workspace(name: trimmed, members: unique)
            workspaces.append(workspace)
            return workspace
        }
    }

    /// Change a stored workspace. The change is applied to the workspace as
    /// read under the lock — never to a copy read earlier — so edits from
    /// the app and the CLI can't undo each other.
    @discardableResult
    public static func update(id: UUID, _ change: (inout Workspace) throws -> Void) throws -> Workspace {
        try modify { workspaces in
            guard let index = workspaces.firstIndex(where: { $0.id == id }) else {
                throw ParallexError("That workspace no longer exists.")
            }
            var updated = workspaces[index]
            try change(&updated)
            let name = updated.name.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
            guard !name.isEmpty else { throw ParallexError("A workspace needs a name.") }
            if let clash = find(name, in: workspaces), clash.id != id {
                throw ParallexError("There's already a workspace named “\(clash.name)”.")
            }
            updated.name = name
            var seen = Set<String>()
            updated.members = updated.members.filter { seen.insert($0).inserted }
            workspaces[index] = updated
            return updated
        }
    }

    public static func delete(id: UUID) throws {
        try modify { workspaces in workspaces.removeAll { $0.id == id } }
    }

    /// Forget a removed instance in every workspace.
    public static func forget(slug: String) {
        _ = try? modify { workspaces in
            for index in workspaces.indices {
                workspaces[index].members.removeAll { $0 == slug }
            }
        }
    }
}

/// Opening and closing a workspace's instances.
public enum WorkspaceLauncher {
    public struct Outcome: Sendable {
        public var opened: [String] = []
        public var failed: [(name: String, reason: String)] = []
    }

    /// Open (or bring forward) every member, in order; with `hidesOthers`,
    /// hide running instances outside the workspace.
    public static func open(_ workspace: Workspace, manifests: [InstanceManifest] = InstanceStore.loadAll()) -> Outcome {
        var outcome = Outcome()
        let members = workspace.instances(in: manifests)
        for manifest in members {
            do {
                try InstanceLauncher.launch(manifest)
                outcome.opened.append(manifest.name)
            } catch {
                outcome.failed.append((manifest.name, "\(error)"))
            }
        }
        if workspace.hidesOthers {
            let memberSlugs = Set(members.map(\.slug))
            for manifest in manifests where !memberSlugs.contains(manifest.slug) {
                if let pid = Running.processID(of: manifest) {
                    onMainThread { _ = NSRunningApplication(processIdentifier: pid)?.hide() }
                }
            }
        }
        return outcome
    }

    /// Ask every running member to quit (apps may ask to save first).
    public static func quit(_ workspace: Workspace, manifests: [InstanceManifest] = InstanceStore.loadAll()) -> [String] {
        var asked: [String] = []
        for manifest in workspace.instances(in: manifests) {
            if let pid = Running.processID(of: manifest) {
                onMainThread { _ = NSRunningApplication(processIdentifier: pid)?.terminate() }
                asked.append(manifest.name)
            }
        }
        return asked
    }
}

/// Who already uses a shortcut — an instance or a workspace — so one key
/// chord never means two things.
public enum ShortcutOwners {
    /// A description of the owner ("“Claude Work”", "the “Work” workspace"),
    /// ignoring the instance slug or workspace id `except`.
    public static func owner(
        of shortcut: KeyShortcut,
        except: String? = nil,
        manifests: [InstanceManifest] = InstanceStore.loadAll(),
        workspaces: [Workspace] = WorkspaceStore.load()
    ) -> String? {
        if let manifest = manifests.first(where: {
            $0.slug != except && $0.settings?.shortcut?.sameKeys(as: shortcut) == true
        }) {
            return "“\(manifest.name)”"
        }
        if let workspace = workspaces.first(where: {
            $0.id.uuidString != except && $0.shortcut?.sameKeys(as: shortcut) == true
        }) {
            return "the “\(workspace.name)” workspace"
        }
        return nil
    }
}
