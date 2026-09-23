import ArgumentParser
import Foundation
import ParallexCore

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect an app: sandbox status, framework, and the isolation mode Parallex would pick."
    )

    @Argument(help: "The app to inspect: a path, a name, or a bundle identifier.")
    var app: String

    @Flag(help: "Output machine-readable JSON.")
    var json = false

    struct Report: Codable {
        var app: String
        var name: String
        var bundleIdentifier: String
        var executable: String
        var signingIdentifier: String?
        var sandboxed: Bool
        var framework: String
        var frameworkDisplayName: String
        var parallexWrapper: Bool
        var recommendedMode: String
        var arguments: [String]
        var environment: [String: String]
        var recipeOptions: [Option]
        var candidateEnvironmentSwitches: [String]
        var notes: [String]

        struct Option: Codable {
            var id: String
            var title: String
            var detail: String
            var defaultEnabled: Bool
        }
    }

    mutating func run() throws {
        let appURL = try AppResolver.resolve(app)
        let info = try AppInspector.inspect(appURL)

        // Show the plan with a placeholder slug — the real path depends on the
        // name chosen at create time.
        let plan = Presets.plan(
            for: info,
            requested: .auto,
            instanceDir: Paths.instanceDir(slug: "<instance>"),
            sharedItems: Presets.defaultSharedItems
        )

        var notes = plan.notes
        if info.isParallexWrapper {
            notes.insert("This app is itself a Parallex wrapper — run doctor on the original app instead.", at: 0)
        }

        // Only worth scanning for apps without a recipe (and Electron ones).
        let switches = plan.availableOptions.isEmpty && Presets.recipe(for: info.bundleID) == nil
            && [.electron, .vscodeFamily].contains(info.framework)
            ? AppInspector.candidateEnvironmentSwitches(appURL: info.url) : []

        let report = Report(
            app: info.url.path,
            name: info.name,
            bundleIdentifier: info.bundleID,
            executable: info.executableURL.path,
            signingIdentifier: info.signingIdentifier,
            sandboxed: info.isSandboxed,
            framework: info.framework.rawValue,
            frameworkDisplayName: info.framework.displayName,
            parallexWrapper: info.isParallexWrapper,
            recommendedMode: plan.mode.rawValue,
            arguments: plan.arguments,
            environment: plan.environment,
            recipeOptions: plan.availableOptions.map {
                Report.Option(id: $0.id, title: $0.title, detail: $0.detail, defaultEnabled: $0.defaultEnabled)
            },
            candidateEnvironmentSwitches: switches,
            notes: notes
        )

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
            return
        }

        print(Term.bold(info.name) + Term.dim("  \(info.url.path)"))
        print("  Bundle ID    \(info.bundleID)")
        print("  Executable   \(info.executableURL.path)")
        let signing = info.signingIdentifier.map { "signed (\($0))" } ?? "unsigned"
        print("  Signing      \(signing)")
        print("  Sandboxed    \(info.isSandboxed ? Term.yellow("yes") : "no")")
        print("  Framework    \(info.framework.displayName)")
        print("")
        print("  Recommended mode: \(Term.bold(plan.mode.rawValue)) — \(plan.mode.summary)")
        if !plan.arguments.isEmpty {
            print("  Launch arguments:")
            for argument in plan.arguments {
                print("    \(Paths.abbreviate(argument))")
            }
        }
        if !plan.environment.isEmpty {
            print("  Launch environment:")
            for (key, value) in plan.environment.sorted(by: { $0.key < $1.key }) {
                print("    \(key)=\(Paths.abbreviate(value))")
            }
        }
        if let home = plan.homeOverride {
            print("  Instance home: \(Paths.abbreviate(home))")
        }
        if !plan.availableOptions.isEmpty {
            print("  Options (turn on with --option <id>):")
            for option in plan.availableOptions {
                let state = option.defaultEnabled ? "on by default" : "off by default"
                print("    \(Term.bold(option.id))  \(option.title) \(Term.dim("(\(state))"))")
            }
        }
        if !switches.isEmpty {
            print("  Possible data-location switches in the app's code (untested):")
            for name in switches {
                print("    \(name)")
            }
            print(Term.dim("  If an instance still shares data with the original, try them with --env NAME=<dir>."))
        }
        print("")
        for note in notes {
            Term.warn(note)
        }
        print("Create an instance with:  parallex create \"\(info.url.path)\" --name \"\(info.name) Work\"")
    }
}
