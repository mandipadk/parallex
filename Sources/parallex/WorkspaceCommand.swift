import ArgumentParser
import Foundation
import ParallexCore

struct WorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace",
        abstract: "Group instances into workspaces that open together.",
        discussion: """
        Examples:
          parallex workspace create Work --add "Claude Work" --add "Slack Work"
          parallex workspace open Work
          parallex workspace shortcut Work ctrl+opt+w
        """,
        subcommands: [List.self, Create.self, Add.self, Drop.self, Open.self, Quit.self, Rename.self, Shortcut.self, Browser.self, Delete.self],
        defaultSubcommand: List.self
    )

    static func lookup(_ name: String) throws -> Workspace {
        if let workspace = WorkspaceStore.find(name) {
            return workspace
        }
        let names = WorkspaceStore.load().map(\.name)
        throw ParallexError("No workspace named '\(name)'. " + (names.isEmpty
            ? "Create one with: parallex workspace create <name>"
            : "Existing workspaces: \(names.joined(separator: ", "))"))
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List workspaces and their instances.")

        @Flag(help: "Print JSON.")
        var json = false

        mutating func run() throws {
            let workspaces = WorkspaceStore.load()
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(workspaces), as: UTF8.self))
                return
            }
            guard !workspaces.isEmpty else {
                print("No workspaces yet. Create one with: parallex workspace create <name> --add <instance>")
                return
            }
            let manifests = InstanceStore.loadAll()
            for workspace in workspaces {
                let members = workspace.instances(in: manifests).map(\.name)
                let shortcut = workspace.shortcut.map { "  \($0.displayString)" } ?? ""
                print("\(Term.bold(workspace.name))\(shortcut)")
                print("  " + (members.isEmpty ? "(no instances)" : members.joined(separator: ", ")))
            }
        }
    }

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a workspace.")

        @Argument(help: "The workspace's name.")
        var name: String

        @Option(name: .customLong("add"), help: ArgumentHelp("An instance to include (repeatable).", valueName: "instance"))
        var instances: [String] = []

        @Flag(help: "Opening the workspace hides running instances that aren't in it.")
        var hideOthers = false

        @Option(help: ArgumentHelp("Its color, as #RRGGBB.", valueName: "hex"))
        var color: String?

        mutating func run() throws {
            if let color, color.count != 7 || !color.hasPrefix("#")
                || !color.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit }) {
                throw ValidationError("Give a color like #0A84FF.")
            }
            let slugs = try instances.map { try lookupInstance($0).slug }
            var workspace = try WorkspaceStore.create(name: name, members: slugs, colorHex: color?.uppercased())
            if hideOthers {
                workspace = try WorkspaceStore.update(id: workspace.id) { $0.hidesOthers = true }
            }
            print("\(Term.green("✓")) Created workspace “\(workspace.name)” with \(slugs.count) instance\(slugs.count == 1 ? "" : "s")")
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add instances to a workspace.")

        @Argument(help: "The workspace.")
        var workspace: String

        @Argument(help: "Instances to add.")
        var instances: [String]

        mutating func run() throws {
            let slugs = try instances.map { try lookupInstance($0).slug }
            let target = try WorkspaceStore.update(id: WorkspaceCommand.lookup(workspace).id) { $0.members += slugs }
            print("\(Term.green("✓")) “\(target.name)” has \(target.members.count) instance\(target.members.count == 1 ? "" : "s")")
        }
    }

    struct Drop: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "remove", abstract: "Take instances out of a workspace.")

        @Argument(help: "The workspace.")
        var workspace: String

        @Argument(help: "Instances to take out.")
        var instances: [String]

        mutating func run() throws {
            let slugs = Set(try instances.map { try lookupInstance($0).slug })
            let target = try WorkspaceStore.update(id: WorkspaceCommand.lookup(workspace).id) {
                $0.members.removeAll { slugs.contains($0) }
            }
            print("\(Term.green("✓")) “\(target.name)” has \(target.members.count) instance\(target.members.count == 1 ? "" : "s")")
        }
    }

    struct Open: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open every instance in a workspace.")

        @Argument(help: "The workspace.")
        var workspace: String

        mutating func run() throws {
            let target = try WorkspaceCommand.lookup(workspace)
            let outcome = WorkspaceLauncher.open(target)
            if !outcome.opened.isEmpty {
                print("\(Term.green("✓")) Opened \(outcome.opened.joined(separator: ", "))")
            } else if outcome.failed.isEmpty {
                print("“\(target.name)” has no instances yet.")
            }
            for failure in outcome.failed {
                print("\(Term.red("✗")) \(failure.name): \(failure.reason)")
            }
            if !outcome.failed.isEmpty {
                throw ExitCode.failure
            }
        }
    }

    struct Quit: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Quit every running instance in a workspace.")

        @Argument(help: "The workspace.")
        var workspace: String

        mutating func run() throws {
            let target = try WorkspaceCommand.lookup(workspace)
            let asked = WorkspaceLauncher.quit(target)
            print(asked.isEmpty ? "Nothing in “\(target.name)” is running." : "\(Term.green("✓")) Asked \(asked.joined(separator: ", ")) to quit")
        }
    }

    struct Rename: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Rename a workspace.")

        @Argument(help: "The workspace.")
        var workspace: String

        @Argument(help: "Its new name.")
        var name: String

        mutating func run() throws {
            let target = try WorkspaceStore.update(id: WorkspaceCommand.lookup(workspace).id) { $0.name = name }
            print("\(Term.green("✓")) Renamed to “\(target.name)”")
        }
    }

    struct Shortcut: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set a global shortcut that opens a workspace (needs the Parallex app running)."
        )

        @Argument(help: "The workspace.")
        var workspace: String

        @Argument(help: "Keys like ctrl+opt+w, or 'none' to remove it.")
        var keys: String

        mutating func run() throws {
            let existing = try WorkspaceCommand.lookup(workspace)
            var shortcut: KeyShortcut?
            if keys.lowercased() != "none" {
                guard let parsed = KeyShortcut(parsing: keys), parsed.isValidGlobal else {
                    throw ValidationError("Use a shortcut with ⌃ or ⌥, like ctrl+opt+w.")
                }
                if parsed.sameKeys(as: KeyShortcut(keyCode: 0x31, modifiers: [.control, .option], key: "Space")) {
                    throw ValidationError("⌃⌥Space opens the switcher.")
                }
                if let owner = ShortcutOwners.owner(of: parsed, except: existing.id.uuidString) {
                    throw ValidationError("\(parsed.displayString) already opens \(owner).")
                }
                shortcut = parsed
            }
            let target = try WorkspaceStore.update(id: existing.id) { $0.shortcut = shortcut }
            print("\(Term.green("✓")) “\(target.name)”: \(target.shortcut?.displayString ?? "no shortcut")")
        }
    }

    struct Browser: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Choose where web links from a workspace's instances open (with `parallex links web on`)."
        )

        @Argument(help: "The workspace.")
        var workspace: String

        @Argument(help: "An instance's name, <Browser>/<Profile> (Chrome/Work), a browser's name, or 'default'.")
        var target: String

        mutating func run() throws {
            let existing = try WorkspaceCommand.lookup(workspace)
            let browsers = WebRouting.browsers()
            let manifests = InstanceStore.loadAll()
            let resolved = try WebRouting.resolveTarget(
                target, manifests: manifests, browsers: browsers, profiles: WebRouting.profiles(in: browsers)
            )
            let updated = try WorkspaceStore.update(id: existing.id) { $0.webLinks = resolved }
            print("\(Term.green("✓")) Web links from “\(updated.name)”: \(WebRouting.describe(resolved, manifests: manifests))")
            if !LinkRouting.loadConfiguration().routesWeb {
                print(Term.dim("Turn web routing on to use it: parallex links web on"))
            }
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a workspace (its instances are kept).")

        @Argument(help: "The workspace.")
        var workspace: String

        mutating func run() throws {
            let target = try WorkspaceCommand.lookup(workspace)
            try WorkspaceStore.delete(id: target.id)
            print("\(Term.green("✓")) Deleted workspace “\(target.name)”")
        }
    }
}
