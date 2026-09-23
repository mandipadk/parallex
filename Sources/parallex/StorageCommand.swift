import ArgumentParser
import Foundation
import ParallexCore

struct Storage: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show an instance's disk usage, and reclaim space.",
        discussion: """
        Caches are rebuilt by the app as needed. Unused items are folders the \
        instance's current settings don't point at (e.g. left over from an \
        earlier isolation mode). Everything removed goes to the Trash, and \
        only while the instance isn't running.
        """
    )

    @Argument(help: "The instance's name or slug; omit for all instances.")
    var instance: String?

    @Flag(help: "Move the instance's caches to the Trash.")
    var cleanCaches = false

    @Flag(help: "Move items the instance no longer uses to the Trash.")
    var removeUnused = false

    mutating func validate() throws {
        if instance == nil && (cleanCaches || removeUnused) {
            throw ValidationError("Name the instance to clean.")
        }
    }

    mutating func run() throws {
        let manifests = try instance.map { [try lookupInstance($0)] } ?? InstanceStore.loadAll()
        for manifest in manifests {
            let report = InstanceStorage.report(for: manifest)
            print("\(Term.bold(manifest.name))  \(InstanceStorage.format(report.totalBytes))")
            if !report.caches.isEmpty {
                print("  Caches        \(InstanceStorage.format(report.cacheBytes))")
            }
            for item in report.unused {
                print("  Unused        \(InstanceStorage.format(item.bytes))  \(Paths.abbreviate(item.url.path))")
            }
            if cleanCaches {
                let count = try InstanceStorage.trash(report.caches.map(\.url), of: manifest)
                print("\(Term.green("✓")) Moved \(count) cache folders to the Trash (\(InstanceStorage.format(report.cacheBytes))).")
            }
            if removeUnused {
                let count = try InstanceStorage.trash(report.unused.map(\.url), of: manifest)
                print("\(Term.green("✓")) Moved \(count) unused items to the Trash (\(InstanceStorage.format(report.unusedBytes))).")
            }
        }
        if cleanCaches || removeUnused {
            print(Term.dim("Empty the Trash to free the space."))
        }
    }
}
