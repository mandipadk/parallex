import ArgumentParser
import Foundation
import ParallexCore

struct CopyData: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy-data",
        abstract: "Start an own-identity copy from the original app's data.",
        discussion: """
        For copies with their own Library: copies the original app's settings, \
        library and file-based sign-ins into the instance (APFS clones — quick, \
        and near-free until they diverge). What the instance had there goes to \
        the Trash. Sign-ins kept in the keychain may need signing in again.
        """
    )

    @Argument(help: "The instance.")
    var instance: String

    @Flag(help: "Only list what would be copied.")
    var dryRun = false

    mutating func run() throws {
        let manifest = try lookupInstance(instance)
        let items = OriginalData.plan(for: manifest)
        if dryRun || items.isEmpty {
            if manifest.redirectedHome == nil {
                print("“\(manifest.name)” uses the real Library; there's nothing to copy.")
            } else if items.isEmpty {
                print("Found nothing of the original app's to copy.")
            } else {
                print("Would copy into “\(manifest.name)”:")
                for item in items { print("  \(item.label)") }
            }
            return
        }
        let copied = try OriginalData.copy(into: manifest)
        print("\(Term.green("✓")) Copied into “\(manifest.name)”: \(copied.map(\.label).joined(separator: ", "))")
    }
}
