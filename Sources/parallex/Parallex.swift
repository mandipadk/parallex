import ArgumentParser
import ParallexCore
import ParallexKit

extension RequestedMode: ExpressibleByArgument {}

@main
struct Parallex: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parallex",
        abstract: "Run multiple isolated instances of any macOS app.",
        discussion: """
        Parallex creates tiny wrapper apps that launch a target app with its own
        Dock identity and its own data, so you can run several fully independent
        copies side by side.

        Examples:
          parallex create Claude --name "Claude Work" --badge W
          parallex create "/Applications/Google Chrome.app" --name "Chrome Dev"
          parallex doctor Slack
          parallex list
          parallex open "Claude Work"
          parallex remove "Claude Work"
        """,
        version: ParallexConfig.version,
        subcommands: [Create.self, List.self, Open.self, Remove.self, Doctor.self]
    )
}
