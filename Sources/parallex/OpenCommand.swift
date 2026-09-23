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
        let manifest = try lookupInstance(instance)
        if original {
            try InstanceLauncher.launchOriginal(of: manifest)
            print("\(Term.green("✓")) Launched the original \(URL(fileURLWithPath: manifest.targetApp).lastPathComponent)")
        } else if reveal {
            guard FileManager.default.fileExists(atPath: manifest.wrapperPath) else {
                throw ParallexError("The wrapper is missing — run: parallex repair \"\(manifest.name)\"")
            }
            try Shell.run("/usr/bin/open", ["-R", manifest.wrapperPath], environment: InstanceLauncher.cleanEnvironment())
        } else {
            let wasRunning = InstanceStatus.check(manifest).running
            try InstanceLauncher.launch(manifest)
            print("\(Term.green("✓")) \(wasRunning ? "Activated" : "Launched") “\(manifest.name)”")
        }
    }
}
