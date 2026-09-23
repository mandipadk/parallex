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

    @Argument(parsing: .postTerminator, help: .hidden)
    var passthroughArguments: [String] = []

    mutating func validate() throws {
        if noBadge && (badge != nil || badgeColor != nil) {
            throw ValidationError("--no-badge can't be combined with --badge or --badge-color.")
        }
        if resetIcon && icon != nil {
            throw ValidationError("--reset-icon can't be combined with --icon.")
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
