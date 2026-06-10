import ArgumentParser
import Foundation
import ParallexCore

struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Launch an instance by name."
    )

    @Argument(help: "The instance's name or slug (see `parallex list`).")
    var instance: String

    @Flag(help: "Reveal the wrapper in Finder instead of launching it.")
    var reveal = false

    @Flag(help: """
    Launch the instance's original app instead. Needed while an instance runs: a running \
    instance adopts the target's identity, so a plain `open` would just focus it.
    """)
    var original = false

    mutating func run() throws {
        guard let manifest = InstanceStore.find(instance) else {
            let names = InstanceStore.loadAll().map(\.name)
            let hint = names.isEmpty
                ? "No instances exist yet."
                : "Existing instances: \(names.joined(separator: ", "))"
            throw ParallexError("No instance named '\(instance)'. \(hint)")
        }
        if original {
            guard FileManager.default.fileExists(atPath: manifest.targetApp) else {
                throw ParallexError("The original app is missing at \(manifest.targetApp).")
            }
            // -n forces a new application instance past Launch Services' dedup.
            try Shell.run("/usr/bin/open", ["-n", manifest.targetApp])
            print("\(Term.green("✓")) Launched the original \(URL(fileURLWithPath: manifest.targetApp).lastPathComponent)")
            return
        }
        guard FileManager.default.fileExists(atPath: manifest.wrapperPath) else {
            throw ParallexError(
                "The wrapper for '\(manifest.name)' is missing at \(manifest.wrapperPath). "
                + "Re-create it with: parallex create \"\(manifest.targetApp)\" --name \"\(manifest.name)\" --force"
            )
        }
        if reveal {
            try Shell.run("/usr/bin/open", ["-R", manifest.wrapperPath])
        } else {
            try Shell.run("/usr/bin/open", [manifest.wrapperPath])
            print("\(Term.green("✓")) Launched “\(manifest.name)”")
        }
    }
}
