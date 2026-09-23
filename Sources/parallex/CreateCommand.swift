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

    @Option(
        name: .customLong("option"),
        help: ArgumentHelp("Turn on an optional isolation setting from the app's recipe (see `doctor`).", valueName: "id")
    )
    var enableOptions: [String] = []

    @Option(
        name: .customLong("no-option"),
        help: ArgumentHelp("Turn off a recipe option that's on by default.", valueName: "id")
    )
    var disableOptions: [String] = []

    @Option(help: ArgumentHelp(
        "Move an existing profile folder in as the instance's data (e.g. an old --user-data-dir), so it starts signed in.",
        valueName: "folder"
    ))
    var adoptData: String?

    @Flag(help: """
    Give the instance its own identity by making a re-signed copy of the app (an APFS clone, \
    almost no extra space): its own Dock icon, notifications, permissions, and — for App Store \
    apps — its own container. See `doctor` for what to expect.
    """)
    var clone = false

    @Flag(help: "Rebuild an existing instance with the same name (its data is kept).")
    var force = false

    @Flag(help: "Launch the instance right after creating it.")
    var open = false

    @Argument(parsing: .postTerminator, help: .hidden)
    var passthroughArguments: [String] = []

    mutating func run() throws {
        var enabledOptions: [String]?
        if !enableOptions.isEmpty || !disableOptions.isEmpty {
            let target = try AppInspector.inspect(try AppResolver.resolve(app))
            let available = Presets.recipe(for: target.bundleID)?.options ?? []
            try checkOptionIDs(enableOptions + disableOptions, available: available)
            var settings = InstanceSettings()
            for id in enableOptions { settings.setOption(id, enabled: true, available: available) }
            for id in disableOptions { settings.setOption(id, enabled: false, available: available) }
            enabledOptions = settings.enabledOptions
        }
        let request = CreateRequest(
            appReference: app,
            name: name,
            mode: mode,
            outputDirectory: URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true),
            badgeText: badge,
            badgeColorHex: badgeColor,
            customIcon: icon.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            environment: try parseEnvironment(environmentEntries),
            extraSharedItems: share,
            includeDefaultSharedItems: !noSharedDefaults,
            extraArguments: passthroughArguments,
            enabledOptions: enabledOptions,
            adoptData: adoptData.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) },
            cloneApp: clone,
            force: force
        )

        let result = try InstanceCreator.create(request)
        printResultSummary(result, verb: "Created")
        print("Launch it from Spotlight or the Dock, or run:  parallex open \"\(result.manifest.name)\"")

        if open {
            _ = try? Shell.run("/usr/bin/open", [result.wrapperURL.path], environment: InstanceLauncher.cleanEnvironment())
        }
    }
}
