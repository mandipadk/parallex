import ArgumentParser
import Foundation
import ParallexCore

struct Remove: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove an instance: its wrapper app and (by default) its data.",
        discussion: "Removed items are moved to the Trash, not deleted outright."
    )

    @Argument(help: "The instance's name or slug (see `parallex list`).")
    var instance: String

    @Flag(help: "Keep the instance's data directory; only remove the wrapper app.")
    var keepData = false

    mutating func run() throws {
        let manifest = try lookupInstance(instance)

        let result = try InstanceRemover.remove(manifest, keepData: keepData)

        if result.wasRunning {
            Term.warn("“\(result.instanceName)” is currently running — it will keep running until you quit it.")
        }
        if result.wrapperTrashed {
            print("\(Term.green("✓")) Moved wrapper to Trash: \(manifest.wrapperPath)")
        }
        if result.wrapperSkippedForeign {
            Term.warn("\(manifest.wrapperPath) is not a Parallex wrapper anymore — leaving it alone.")
        }
        if result.wrapperWasMissing {
            print(Term.dim("Wrapper was already gone: \(manifest.wrapperPath)"))
        }
        if result.dataTrashed {
            print("\(Term.green("✓")) Moved instance data to Trash: \(Paths.abbreviate(Paths.instanceDir(slug: manifest.slug).path))")
        }
        if let container = result.leftoverContainer {
            print("The copy's sandbox container is still at \(Paths.abbreviate(container)) — macOS only lets you")
            print("delete it yourself (drag it to the Trash in Finder).")
        }
        if let kept = result.dataKeptAt {
            print("Kept data at \(Paths.abbreviate(kept))")
        }
    }
}
