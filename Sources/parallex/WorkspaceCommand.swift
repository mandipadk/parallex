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
        subcommands: [List.self, Create.self, Add.self, Drop.self, Open.self, Quit.self, Rename.self, Shortcut.self, Browser.self, Persona.self, Proxy.self, Delete.self],
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

    struct Proxy: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Send a workspace's instances (and parallex run) through a proxy, or stop.",
            discussion: """
            Chromium and Electron apps in it get --proxy-server; everything its instances \
            start, and parallex run, get HTTP_PROXY, HTTPS_PROXY and ALL_PROXY. Instances \
            pick it up the next time they open.

            Examples:
              parallex workspace proxy "Client A" http://proxy.client.example:8080
              parallex workspace proxy "Client A" socks5://127.0.0.1:1080
              parallex workspace proxy "Client A" off
            """
        )

        @Argument(help: "The workspace.")
        var workspace: String

        @Argument(help: "The proxy (scheme://host:port), or off. Leave out to see it.")
        var proxy: String?

        mutating func run() throws {
            var chosen = try WorkspaceCommand.lookup(workspace)
            if let proxy {
                let value: String?
                if proxy == "off" {
                    value = nil
                } else {
                    guard let normalized = WorkspaceNetwork.normalize(proxy) else {
                        throw ValidationError("That isn't a proxy address: use scheme://host:port, like http://proxy.example:8080.")
                    }
                    value = normalized
                }
                chosen = try WorkspaceStore.update(id: chosen.id) { $0.proxy = value }
            }
            if let current = chosen.proxy {
                print("\(Term.bold(chosen.name)) goes through \(current).")
            } else {
                print("\(Term.bold(chosen.name)) goes straight out, like the rest of your Mac.")
            }
        }
    }

    struct Persona: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Give a workspace its own identity for your tools (see `parallex run`), or share yours again.",
            discussion: """
            Examples:
              parallex workspace persona Work on
              parallex workspace persona Work --item .config/op
              parallex workspace persona Work off
            """
        )

        @Argument(help: "The workspace.")
        var workspace: String

        @Argument(help: "on or off (leave out to see how it is).")
        var state: String?

        @Option(name: .customLong("item"), help: ArgumentHelp("One more item in your home that's the workspace's own. Repeatable.", valueName: "item"))
        var add: [String] = []

        @Option(name: .customLong("no-item"), help: ArgumentHelp("Share an item again. Repeatable.", valueName: "item"))
        var remove: [String] = []

        mutating func run() throws {
            var chosen = try WorkspaceCommand.lookup(workspace)
            if state != nil || !add.isEmpty || !remove.isEmpty {
                guard state == nil || state == "on" || state == "off" else {
                    throw ValidationError("Say on or off.")
                }
                let tidy = { (item: String) in item.hasPrefix("~/") ? String(item.dropFirst(2)) : item }
                let adding = add.map(tidy)
                let removing = Set(remove.map(tidy))
                let before = Set(ParallexCore.Personas.items(for: chosen))
                chosen = try WorkspaceStore.update(id: chosen.id) { workspace in
                    if let state { workspace.persona = state == "on" ? true : nil }
                    if !adding.isEmpty || !removing.isEmpty {
                        var items = ParallexCore.Personas.items(for: workspace)
                        items += adding.filter { !items.contains($0) }
                        items.removeAll { removing.contains($0) }
                        workspace.personaItems = items
                    }
                }
                // Shared again: the persona's own version goes to the Trash,
                // and its home links to yours there again.
                let released = before.subtracting(ParallexCore.Personas.items(for: chosen))
                if !released.isEmpty {
                    InstanceCreator.releasePrivateItems(released.sorted(), home: ParallexCore.Personas.home(for: chosen))
                }
            }
            let home = ParallexCore.Personas.home(for: chosen)
            if chosen.persona == true {
                ParallexCore.Personas.prepare(chosen)
                print("\(Term.bold(chosen.name)) has an identity of its own for your tools, at \(Paths.abbreviate(home.path)).")
                print("Its own: " + ParallexCore.Personas.items(for: chosen).map { "~/\($0)" }.joined(separator: ", "))
                let yours = Identities.read(home: FileManager.default.homeDirectoryForCurrentUser)
                let theirs = Identities.read(home: home)
                print("")
                let width = max(12, (yours.map(\.tool) + ["Tool"]).map(\.count).max() ?? 12) + 2
                let column = { (text: String) in text.padding(toLength: width, withPad: " ", startingAt: 0) }
                print(Term.dim(column("") + "You  →  \(chosen.name)"))
                for (mine, its) in zip(yours, theirs) {
                    print(column(mine.tool) + (mine.identity ?? "–") + "  →  " + (its.identity ?? Term.dim("not set up yet")))
                }
                print(Term.dim("Use it with: parallex run \"\(chosen.name)\" -- <command>, or parallex shell \"\(chosen.name)\"."))
            } else {
                print("\(Term.bold(chosen.name)) uses your identity for your tools.")
                if FileManager.default.fileExists(atPath: home.path) {
                    print(Term.dim("What its persona had is kept at \(Paths.abbreviate(home.path)), for when it's on again."))
                }
            }
        }
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
