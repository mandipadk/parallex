import ArgumentParser
import Foundation
import ParallexCore

struct Create: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create a new isolated instance of an app.",
        discussion: """
        Arguments after `--` are passed through to the target binary:
          parallex create Claude --name "Claude Dev" -- --remote-debugging-port=9222
        """
    )

    @Argument(help: "The target app: a path (/Applications/Claude.app), a name (Claude), or a bundle identifier.")
    var app: String

    @Option(name: .shortAndLong, help: "Display name for the instance (default: \"<App> 2\", \"<App> 3\", …).")
    var name: String?

    @Option(help: "Isolation mode. 'auto' picks the best mode for the app.")
    var mode: RequestedMode = .auto

    @Option(help: "Directory the wrapper app is written to.")
    var out: String = "/Applications"

    @Option(help: "1–2 characters drawn as a colored badge on the icon so instances are easy to tell apart.")
    var badge: String?

    @Option(help: "Badge color as #RRGGBB (default: a stable color derived from the instance name).")
    var badgeColor: String?

    @Option(help: "Custom icon file (.icns or any image) instead of the target app's icon.")
    var icon: String?

    @Option(
        name: .customLong("env"),
        help: ArgumentHelp("Extra environment variable for the instance, as KEY=VALUE.", valueName: "key=value")
    )
    var environmentEntries: [String] = []

    @Option(
        name: .customLong("share"),
        help: ArgumentHelp(
            "Extra item from your real home to share into the instance home (home mode), e.g. '.config/gh'.",
            valueName: "path"
        )
    )
    var share: [String] = []

    @Flag(help: "Don't share the default items (Desktop, Documents, Downloads, …) into the instance home.")
    var noSharedDefaults = false

    @Flag(help: "Rebuild an existing instance with the same name (its data is kept).")
    var force = false

    @Flag(help: "Launch the instance right after creating it.")
    var open = false

    @Argument(parsing: .postTerminator, help: .hidden)
    var passthroughArguments: [String] = []

    mutating func run() throws {
        let request = CreateRequest(
            appReference: app,
            name: name,
            mode: mode,
            outputDirectory: URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true),
            badgeText: badge,
            badgeColorHex: badgeColor,
            customIcon: icon.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            environment: try parseEnvironment(),
            extraSharedItems: share,
            includeDefaultSharedItems: !noSharedDefaults,
            extraArguments: passthroughArguments,
            force: force
        )

        let result = try InstanceCreator.create(request)
        printSummary(result)

        if open {
            _ = try? Shell.run("/usr/bin/open", [result.wrapperURL.path])
        }
    }

    private func parseEnvironment() throws -> [String: String] {
        var environment: [String: String] = [:]
        for entry in environmentEntries {
            guard let separator = entry.firstIndex(of: "="), separator != entry.startIndex else {
                throw ParallexError("--env expects KEY=VALUE, got '\(entry)'.")
            }
            environment[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        return environment
    }

    private func printSummary(_ result: CreateResult) {
        let manifest = result.manifest
        print("\(Term.green("✓")) Created \(Term.bold("“\(manifest.name)”"))")
        print("  Wrapper  \(manifest.wrapperPath)")
        print("  Target   \(manifest.targetApp)  \(Term.dim("(\(result.frameworkDisplayName))"))")
        print("  Mode     \(manifest.mode.rawValue) — \(manifest.mode.summary)")
        for directory in result.dataDirectories {
            print("  Data     \(Paths.abbreviate(directory))")
        }
        if let home = result.homeDirectory {
            print("  Home     \(Paths.abbreviate(home))")
        }
        print("")
        for warning in result.warnings {
            Term.warn(warning)
        }
        for note in result.notes {
            Term.warn(note)
        }
        print("Launch it from Spotlight or the Dock, or run:  open \"\(manifest.wrapperPath)\"")
    }
}
