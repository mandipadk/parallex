import ArgumentParser
import Foundation
import ParallexCore

struct SnapshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Keep an instance's data as it is now, and go back to it later.",
        discussion: """
        A snapshot holds the instance's data folders, its own keychain and a \
        copy's preferences. Taking one is instant and takes no space until the \
        instance's data moves on from it (APFS clones). Restoring one keeps what \
        the instance had as a snapshot too, so a restore can be undone.

        Examples:
          parallex snapshot take "Slack Work" --label "before the reorg"
          parallex snapshot list "Slack Work"
          parallex snapshot restore "Slack Work" 20260929-201500
        """,
        subcommands: [List.self, Take.self, Restore.self, Rename.self, Delete.self],
        defaultSubcommand: List.self
    )

    static func lookup(_ id: String, in manifest: InstanceManifest) throws -> Snapshots.Snapshot {
        if let snapshot = Snapshots.find(id, in: manifest) {
            return snapshot
        }
        let ids = Snapshots.list(manifest).map(\.id)
        throw ParallexError("“\(manifest.name)” has no snapshot \(id). " + (ids.isEmpty
            ? "Take one with: parallex snapshot take \"\(manifest.name)\""
            : "Its snapshots: \(ids.joined(separator: ", "))"))
    }

    static func describe(_ snapshot: Snapshots.Snapshot) -> String {
        var text = "\(Term.bold(snapshot.id))  \(snapshot.date.formatted(date: .abbreviated, time: .shortened))"
        if let label = snapshot.label {
            text += "  \(label)"
        }
        switch snapshot.reason {
        case .beforeRestore: text += Term.dim("  before a restore")
        case .beforeRefresh: text += Term.dim("  kept before an update")
        case .daily: text += Term.dim("  daily")
        case .manual: break
        }
        if let version = snapshot.appVersion {
            text += Term.dim("  app \(version)")
        }
        return text
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List an instance's snapshots, newest first.")

        @Argument(help: "The instance.")
        var instance: String

        @Flag(help: "Print JSON.")
        var json = false

        mutating func run() throws {
            let manifest = try lookupInstance(instance)
            let snapshots = Snapshots.list(manifest)
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                print(String(decoding: try encoder.encode(snapshots), as: UTF8.self))
                return
            }
            guard !snapshots.isEmpty else {
                print("“\(manifest.name)” has no snapshots. Take one with: parallex snapshot take \"\(manifest.name)\"")
                return
            }
            for snapshot in snapshots {
                print(SnapshotCommand.describe(snapshot))
            }
        }
    }

    struct Take: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Take a snapshot of an instance that isn't running.")

        @Argument(help: "The instance.")
        var instance: String

        @Option(help: "A few words to remember it by.")
        var label: String?

        mutating func run() throws {
            let manifest = try lookupInstance(instance)
            let snapshot = try Snapshots.take(manifest, label: label)
            print("\(Term.green("✓")) Took a snapshot of “\(manifest.name)”: \(snapshot.id)")
        }
    }

    struct Restore: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Put an instance's data back as it was in a snapshot.",
            discussion: "What it has now is kept as a snapshot first, so you can go back to it the same way."
        )

        @Argument(help: "The instance.")
        var instance: String

        @Argument(help: "The snapshot (as `parallex snapshot list` shows it).")
        var snapshot: String

        mutating func run() throws {
            let manifest = try lookupInstance(instance)
            let chosen = try SnapshotCommand.lookup(snapshot, in: manifest)
            let before = try Snapshots.restore(chosen, of: manifest)
            print("\(Term.green("✓")) “\(manifest.name)” is back to \(chosen.id).")
            print(Term.dim("What it had until now is snapshot \(before.id)."))
        }
    }

    struct Rename: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change a snapshot's label.")

        @Argument(help: "The instance.")
        var instance: String

        @Argument(help: "The snapshot.")
        var snapshot: String

        @Argument(help: "The new label (leave out to remove it).")
        var label: String?

        mutating func run() throws {
            let manifest = try lookupInstance(instance)
            try Snapshots.rename(try SnapshotCommand.lookup(snapshot, in: manifest), of: manifest, to: label)
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a snapshot.")

        @Argument(help: "The instance.")
        var instance: String

        @Argument(help: "The snapshot.")
        var snapshot: String

        mutating func run() throws {
            let manifest = try lookupInstance(instance)
            try Snapshots.delete(try SnapshotCommand.lookup(snapshot, in: manifest), of: manifest)
            print("\(Term.green("✓")) Deleted snapshot \(snapshot) of “\(manifest.name)”.")
        }
    }
}
