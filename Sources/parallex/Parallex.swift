import ArgumentParser
import ParallexCore
import ParallexKit

extension RequestedMode: ExpressibleByArgument {}

@main
struct Parallex: AsyncParsableCommand {
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
          parallex edit "Claude Work" --badge W --option separate-claude-code
          parallex workspace create Work --add "Claude Work"
          parallex repair --all
          parallex remove "Claude Work"
        """,
        version: ParallexConfig.version,
        subcommands: [
            Create.self, Apps.self, List.self, Open.self, Edit.self, Duplicate.self, CopyData.self,
            WorkspaceCommand.self, RunAs.self, ShellAs.self, Links.self, Check.self, Storage.self, Health.self, SnapshotCommand.self, VersionsCommand.self, Export.self, Import.self,
            Repair.self, Remove.self, Doctor.self, Report.self, Usage.self, Notices.self,
        ]
    )

    /// As ArgumentParser runs a command, and counted by which one (for the
    /// usage report, see `Telemetry`): only its name, never what it was given.
    static func main() async {
        do {
            var command = try parseAsRoot()
            if let name = topLevel(type(of: command)) {
                Telemetry.record("cli.command", ["command": name])
            }
            if var command = command as? AsyncParsableCommand {
                try await command.run()
            } else {
                try command.run()
            }
        } catch {
            exit(withError: error)
        }
    }

    /// The top-level command `command` is, or is under.
    static func topLevel(_ command: ParsableCommand.Type) -> String? {
        func holds(_ parent: ParsableCommand.Type) -> Bool {
            ObjectIdentifier(parent) == ObjectIdentifier(command) || parent.configuration.subcommands.contains(where: holds)
        }
        return configuration.subcommands.first(where: holds)?._commandName
    }
}
