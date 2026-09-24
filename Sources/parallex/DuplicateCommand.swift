import ArgumentParser
import Foundation
import ParallexCore

struct Duplicate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Make another instance with the same app and settings.",
        discussion: """
        The new instance starts empty (signed out) unless --with-data copies \
        the original instance's data — an APFS clone, so it's quick and takes \
        almost no space until the two diverge.
        """
    )

    @Argument(help: "The instance to duplicate.")
    var instance: String

    @Option(help: "Name for the new instance (default: “<name> Copy”).")
    var name: String?

    @Flag(help: "Copy the instance's data too (quit it first).")
    var withData = false

    mutating func run() throws {
        let manifest = try lookupInstance(instance)
        let result = try InstanceCreator.duplicate(manifest, name: name, includeData: withData)
        printResultSummary(result, verb: "Created")
        if withData {
            print("  Copied the data of “\(manifest.name)”.")
        }
    }
}
