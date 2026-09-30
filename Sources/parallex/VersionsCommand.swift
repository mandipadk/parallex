import ArgumentParser
import Foundation
import ParallexCore

struct VersionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "versions",
        abstract: "Go back to an earlier version of a copy's app, and forward again.",
        discussion: """
        An own-identity copy keeps the app version it was built from, so when \
        the app updates, the previous version is still there. A copy can stay \
        on it (it isn't refreshed while it does), and, with --with-data, its \
        data can go back to how that version left it.

        Examples:
          parallex versions "Slack Work"
          parallex versions use "Slack Work" 4.41.105 --with-data
          parallex versions use "Slack Work" --current
        """,
        subcommands: [List.self, Use.self, Remove.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the versions of a copy's app that are kept.")

        @Argument(help: "The instance.")
        var instance: String

        mutating func run() throws {
            let manifest = try lookupInstance(instance)
            let current = AppCloner.version(of: URL(fileURLWithPath: manifest.targetApp))
            let inUse = manifest.clone?.sourceVersion
            let kept = AppVersions.list(manifest)
            print("\(Term.bold(manifest.name)) runs \(inUse ?? current)" + (manifest.effectiveSettings.pinnedVersion != nil
                ? Term.dim(", staying there while the app in /Applications is \(current)") : ""))
            guard !kept.isEmpty else {
                print("No versions kept yet. The next time it's built, the version it's built from is kept.")
                return
            }
            for version in kept {
                var line = "  \(version.version)"
                if version.version == inUse { line += Term.dim("  in use") }
                if let snapshot = AppVersions.snapshotBefore(leaving: version.version, of: manifest) {
                    line += Term.dim("  data as it left it: snapshot \(snapshot.id)")
                }
                print(line)
            }
        }
    }

    struct Use: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build a copy from a kept version of its app, or the current one again."
        )

        @Argument(help: "The instance.")
        var instance: String

        @Argument(help: "The version (as `parallex versions` lists it).")
        var version: String?

        @Flag(help: "Go back to the version of the app in /Applications, and keep up with it again.")
        var current = false

        @Flag(help: "Also put the data back as that version left it.")
        var withData = false

        mutating func run() throws {
            let manifest = try lookupInstance(instance)
            let now = AppCloner.version(of: URL(fileURLWithPath: manifest.targetApp))
            guard let chosen = current ? now : version else {
                throw ValidationError("Give a version, or --current.")
            }
            let result = try AppVersions.use(chosen, for: manifest, restoreData: withData)
            if result.effectiveSettings.pinnedVersion == nil {
                print("\(Term.green("✓")) “\(result.name)” runs \(now), and keeps up with the app again.")
            } else {
                print("\(Term.green("✓")) “\(result.name)” runs \(chosen), and stays there when the app updates.")
            }
            if withData {
                print(Term.dim("Its data is back as \(chosen) left it; what it had is a snapshot too."))
            }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Move a kept version to the Trash.")

        @Argument(help: "The instance.")
        var instance: String

        @Argument(help: "The version.")
        var version: String

        mutating func run() throws {
            let manifest = try lookupInstance(instance)
            guard let kept = AppVersions.list(manifest).first(where: { $0.version == version }) else {
                throw ParallexError("\(version) isn't kept for “\(manifest.name)”.")
            }
            try AppVersions.remove(kept, of: manifest)
            print("\(Term.green("✓")) Moved \(version) to the Trash.")
        }
    }
}
