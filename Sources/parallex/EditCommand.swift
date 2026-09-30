import ArgumentParser
import Foundation
import ParallexCore

struct Edit: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Change an instance: rename it, restyle its icon, or adjust its isolation.",
        discussion: """
        The instance keeps its data, bundle ID, and macOS permissions. Changes \
        take effect the next time the instance launches.

        Arguments after `--` replace the extra arguments passed to the app:
          parallex edit "Chrome Dev" -- --remote-debugging-port=9333
        """
    )

    @Argument(help: "The instance's name or slug (see `parallex list`).")
    var instance: String

    @Option(help: "New display name (also renames the wrapper app).")
    var name: String?

    @Option(help: "1–2 characters drawn as a badge on the icon.")
    var badge: String?

    @Option(help: "Badge color as #RRGGBB.")
    var badgeColor: String?

    @Flag(help: "Remove the badge.")
    var noBadge = false

    @Option(help: "Custom icon file (.icns or any image).")
    var icon: String?

    @Flag(help: "Go back to the original app's icon.")
    var resetIcon = false

    @Option(help: "Isolation mode.")
    var mode: RequestedMode?

    @Option(name: .customLong("option"), help: ArgumentHelp("Turn on a recipe option.", valueName: "id"))
    var enableOptions: [String] = []

    @Option(name: .customLong("no-option"), help: ArgumentHelp("Turn off a recipe option.", valueName: "id"))
    var disableOptions: [String] = []

    @Option(name: .customLong("env"), help: ArgumentHelp("Set an extra environment variable.", valueName: "key=value"))
    var setEnvironment: [String] = []

    @Option(name: .customLong("unset-env"), help: ArgumentHelp("Remove an extra environment variable.", valueName: "key"))
    var unsetEnvironment: [String] = []

    @Flag(inversion: .prefixedNo, help: "Turn clone mode (own identity) on or off.")
    var clone: Bool?

    @Flag(help: "Remove all extra arguments.")
    var clearArgs = false

    @Flag(inversion: .prefixedNo, help: "Keep an own-identity copy's ~/Library separate (on by default).")
    var separateLibrary: Bool?

    @Flag(inversion: .prefixedNo, help: "Keep the app's own hidden folders in your home (like ~/.vscode) separate too (on by default).")
    var separateHiddenFolders: Bool?

    @Flag(inversion: .prefixedNo, help: "Keep an own-identity copy's sign-ins in a keychain of its own (on by default for new copies).")
    var separateKeychain: Bool?

    @Option(name: .customLong("private"), help: ArgumentHelp(
        "Keep one more item in your home (like .config/acme) to an own-identity copy with its own hidden folders. Repeatable.",
        valueName: "item"
    ))
    var addPrivate: [String] = []

    @Option(name: .customLong("no-private"), help: ArgumentHelp("Share an item added with --private again. Repeatable.", valueName: "item"))
    var removePrivate: [String] = []

    @Flag(inversion: .prefixedNo, help: "Keep the version of the app an own-identity copy was on when the app updates, to go back to (on by default).")
    var keepPreviousVersion: Bool?

    @Flag(inversion: .prefixedNo, help: "An editor copy uses the original's settings, keybindings, snippets and extensions, kept in step (off by default).")
    var shareSettings: Bool?

    @Flag(inversion: .prefixedNo, help: "Take a snapshot of the instance once a day, when it isn't running (off by default).")
    var dailySnapshots: Bool?

    @Flag(name: .customLong("guard"), inversion: .prefixedNo, help: "Keep an own-identity copy out of the original's data, even by its full path (on by default).")
    var guardOriginalData: Bool?

    @Option(help: ArgumentHelp(
        "Global shortcut that opens the instance, e.g. ctrl+opt+1 or ⌃⌥W (needs the Parallex app running).",
        valueName: "keys"
    ))
    var shortcut: String?

    @Flag(help: "Remove the instance's global shortcut.")
    var noShortcut = false

    @Option(help: ArgumentHelp("A web instance's new address.", valueName: "url"))
    var web: String?

    @Flag(inversion: .prefixedNo, help: "Hide an own-identity copy from the Dock and ⌘-Tab (open it from its menu bar icon or shortcut).")
    var hideFromDock: Bool?

    @Flag(inversion: .prefixedNo, help: "Show an icon in the menu bar that opens the instance (needs the Parallex app running).")
    var menuBarIcon: Bool?

    @Flag(inversion: .prefixedNo, help: "Make it a throwaway: once it has run and quit, the Parallex app moves it and its data to the Trash.")
    var throwaway: Bool?

    @Option(help: ArgumentHelp(
        "Quit it once it hasn't been in front for this many minutes, unless it's playing sound (needs the Parallex app running); `off` to stop.",
        valueName: "minutes"
    ))
    var quitWhenUnused: String?

    @Argument(parsing: .postTerminator, help: .hidden)
    var passthroughArguments: [String] = []

    mutating func validate() throws {
        if noBadge && (badge != nil || badgeColor != nil) {
            throw ValidationError("--no-badge can't be combined with --badge or --badge-color.")
        }
        if resetIcon && icon != nil {
            throw ValidationError("--reset-icon can't be combined with --icon.")
        }
        if noShortcut && shortcut != nil {
            throw ValidationError("--no-shortcut can't be combined with --shortcut.")
        }
        if let shortcut {
            guard let parsed = KeyShortcut(parsing: shortcut) else {
                throw ValidationError("Couldn't read the shortcut “\(shortcut)”. Use a form like ctrl+opt+1 or cmd+shift+k.")
            }
            guard parsed.isValidGlobal else {
                throw ValidationError("A global shortcut needs ⌃ or ⌥ (or a function key), so it doesn't take over typing or app shortcuts like ⌘C.")
            }
        }
    }

    mutating func run() throws {
        let manifest = try lookupInstance(instance)
        var settings = manifest.effectiveSettings

        if noBadge {
            settings.badgeText = nil
            settings.badgeColorHex = nil
        }
        if let badge {
            settings.badgeText = badge.trimmingCharacters(in: .whitespaces)
        }
        if let badgeColor {
            settings.badgeColorHex = badgeColor
        }
        if resetIcon {
            settings.customIconFile = nil
        }
        if let mode {
            settings.mode = mode
        }
        if let clone {
            settings.cloneApp = clone ? true : nil
        }
        if let separateLibrary {
            settings.separateLibrary = separateLibrary
        }
        if let separateHiddenFolders {
            settings.separateHiddenFolders = separateHiddenFolders
        }
        if let separateKeychain {
            settings.separateKeychain = separateKeychain
        }
        if let guardOriginalData {
            settings.guardOriginalData = guardOriginalData
        }
        if let shareSettings {
            settings.shareSettings = shareSettings ? true : nil
        }
        if let dailySnapshots {
            settings.dailySnapshots = dailySnapshots ? true : nil
        }
        if let keepPreviousVersion {
            settings.keepPreviousVersion = keepPreviousVersion ? nil : false
        }
        if !addPrivate.isEmpty || !removePrivate.isEmpty {
            let normalize = { (item: String) in
                item.hasPrefix("~/") ? String(item.dropFirst(2)) : item
            }
            var items = settings.extraPrivateItems ?? []
            for item in addPrivate.map(normalize) where !items.contains(item) {
                items.append(item)
            }
            let removed = Set(removePrivate.map(normalize))
            items.removeAll { removed.contains($0) }
            settings.extraPrivateItems = items.isEmpty ? nil : items
        }
        if let menuBarIcon {
            settings.menuBarIcon = menuBarIcon ? true : nil
        }
        if let quitWhenUnused {
            if quitWhenUnused.lowercased() == "off" {
                settings.quitWhenUnused = nil
            } else if let minutes = Int(quitWhenUnused), minutes >= 5 {
                settings.quitWhenUnused = minutes
            } else {
                throw ValidationError("--quit-when-unused takes a number of minutes (5 or more), or off.")
            }
        }
        if let throwaway {
            guard !throwaway || Throwaway.isPossible(for: manifest) else {
                throw ValidationError("A copy of a sandboxed app can't be a throwaway: it starts without Parallex's launcher, so Parallex can't tell when it has run.")
            }
            settings.throwaway = throwaway ? true : nil
        }
        if let hideFromDock {
            guard settings.isClone || !hideFromDock else {
                throw ValidationError("Only an own-identity copy can leave the Dock: turn on --clone first.")
            }
            settings.hideFromDock = hideFromDock ? true : nil
            // Its way back, unless it has a shortcut or you said otherwise.
            if hideFromDock, menuBarIcon == nil, settings.shortcut == nil {
                settings.menuBarIcon = true
                print(Term.dim("It gets a menu bar icon to open it with (--no-menu-bar-icon to leave it out)."))
            }
        }
        if !settings.isClone {
            settings.hideFromDock = nil
        }
        if let web {
            guard manifest.isWeb else {
                throw ValidationError("“\(manifest.name)” isn't a web instance.")
            }
            guard let url = WebShell.normalizedURL(web) else {
                throw ValidationError("“\(web)” isn't a web address.")
            }
            settings.webURL = url.absoluteString
        }
        let available = manifest.recipe?.options ?? []
        try checkOptionIDs(enableOptions + disableOptions, available: available)
        for id in enableOptions { settings.setOption(id, enabled: true, available: available) }
        for id in disableOptions { settings.setOption(id, enabled: false, available: available) }
        settings.extraEnvironment.merge(try parseEnvironment(setEnvironment)) { _, new in new }
        for key in unsetEnvironment {
            settings.extraEnvironment[key] = nil
        }
        if clearArgs {
            settings.extraArguments = []
        }
        if !passthroughArguments.isEmpty {
            settings.extraArguments = passthroughArguments
        }
        if noShortcut {
            settings.shortcut = nil
        }
        if let shortcut, let parsed = KeyShortcut(parsing: shortcut) {
            if let owner = ShortcutOwners.owner(of: parsed, except: manifest.slug) {
                throw ValidationError("\(parsed.displayString) already opens \(owner).")
            }
            settings.shortcut = parsed
        }

        // Bookkeeping-only changes (a shortcut) save without a rebuild.
        if name == nil, icon == nil, !resetIcon, !noBadge,
           !manifest.effectiveSettings.requiresRebuild(toReach: settings) {
            let saved = try InstanceCreator.saveSettings(settings, for: manifest)
            print("\(Term.green("✓")) Updated “\(saved.name)”")
            if let shortcut = saved.settings?.shortcut {
                print("  Shortcut  \(shortcut.displayString)")
            }
            return
        }

        let result = try InstanceCreator.update(
            manifest,
            InstanceUpdate(
                name: name,
                settings: settings,
                newCustomIcon: icon.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
                // Pre-0.5 instances have their badge baked into the icon.
                resetIcon: resetIcon || noBadge
            )
        )
        printResultSummary(result, verb: "Updated")
        if InstanceStatus.check(result.manifest).running {
            Term.warn("“\(result.manifest.name)” is running — quit and reopen it for the changes to apply.")
        }
    }
}

struct Repair: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rebuild an instance's wrapper from its saved settings.",
        discussion: """
        Fixes a deleted or damaged wrapper, records a moved original app, and \
        brings wrappers built by older Parallex versions up to date. Data, \
        bundle ID, and permissions are kept.
        """
    )

    @Argument(help: "The instance's name or slug, or --all.")
    var instance: String?

    @Flag(help: "Repair every instance that reports a problem.")
    var all = false

    @Option(help: "Where the original app is now, if Parallex can't find it.")
    var app: String?

    mutating func validate() throws {
        if (instance == nil) == !all {
            throw ValidationError("Name one instance, or pass --all.")
        }
        if all && app != nil {
            throw ValidationError("--app only applies to a single instance.")
        }
    }

    mutating func run() throws {
        let manifests = all
            ? InstanceStore.loadAll().filter { !InstanceStatus.check($0).problems.isEmpty }
            : [try lookupInstance(instance!)]
        if manifests.isEmpty {
            print("Nothing to repair.")
            return
        }
        var failures = 0
        for manifest in manifests {
            do {
                let target = try app.map { try AppResolver.resolve($0) }
                // A running copy can't be replaced underneath itself: its
                // refresh is built now and takes over when it quits.
                let problems = InstanceStatus.check(manifest).problems
                if manifest.clone != nil, target == nil, Running.isRunning(manifest),
                   !problems.contains(.copyReplaced) {
                    try InstanceCreator.stageRefresh(manifest)
                    print("\(Term.green("✓")) “\(manifest.name)” is running: its refreshed copy is ready and takes over when it quits")
                    continue
                }
                let result = try InstanceCreator.update(manifest, InstanceUpdate(targetApp: target))
                print("\(Term.green("✓")) Repaired “\(result.manifest.name)”")
                for warning in result.warnings {
                    Term.warn(warning)
                }
            } catch {
                failures += 1
                print("\(Term.red("✗")) “\(manifest.name)”: \(error)")
            }
        }
        if failures > 0 {
            throw ExitCode.failure
        }
    }
}
