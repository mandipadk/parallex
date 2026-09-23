import Foundation

/// Isolation mode as requested by the user; `auto` resolves to a concrete
/// `InstanceMode` via `Presets.plan`.
public enum RequestedMode: String, CaseIterable, Sendable {
    case auto
    case dataDir = "data-dir"
    case home
    case launchOnly = "launch-only"
}

/// The fully resolved isolation recipe for one instance: which mode, which
/// launch arguments and environment, what the launcher must scaffold, and
/// anything the user should be told.
public struct IsolationPlan: Sendable {
    public var mode: InstanceMode
    public var presetID: String?
    public var arguments: [String]
    public var createDirectories: [String]
    public var homeOverride: String?
    public var homeSymlinks: [String]
    /// Environment variables that implement the isolation (some apps ignore
    /// flags but honor env vars, e.g. Codex's CODEX_ELECTRON_USER_DATA_PATH).
    public var environment: [String: String]
    public var notes: [String]
    /// Toggles the app's recipe offers (e.g. separate Claude Code config).
    public var availableOptions: [RecipeOption] = []
    /// The option IDs this plan applied.
    public var enabledOptions: [String] = []
}

/// A per-app isolation recipe: what data-dir isolation means for one app.
public struct AppRecipe: Sendable {
    /// Stable identifier, stored as the instance's preset.
    public let id: String
    let bundleIDPrefixes: [String]
    let arguments: [String]
    let environment: [String: String]
    let createDirectories: [String]
    let note: String
    public let options: [RecipeOption]
    /// Folders (relative to home) the app always shares with the original,
    /// because nothing the app reads can move them — with the reason.
    var unavoidablyShared: [(path: String, reason: String)] = []

    func matches(bundleID: String) -> Bool {
        bundleIDPrefixes.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }
}

/// An optional extra piece of isolation a recipe offers, for state users may
/// reasonably want either shared or separate.
public struct RecipeOption: Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let detail: String
    public let defaultEnabled: Bool
    let environment: [String: String]
    let createDirectories: [String]
}

public enum Presets {
    /// Items symlinked from the real home into an instance home so user files
    /// stay shared while app data (~/Library) is isolated.
    public static let defaultSharedItems = [
        "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures",
        ".gitconfig", ".ssh",
    ]

    /// Per-app isolation recipes, for apps where framework flags alone are
    /// wrong or incomplete. Some Electron apps pin their data directory in
    /// code (app.setPath('userData', …)), so --user-data-dir does nothing —
    /// but they often honor their own environment variables instead.
    /// `${instance}` in values expands to the instance directory.
    static let recipes: [AppRecipe] = [
        // Codex calls app.setPath('userData', …) — its userData (and the
        // single-instance lock inside it) is pinned in code, and its session
        // lives in ~/.codex. Both have env overrides in Codex's own code:
        // CODEX_ELECTRON_USER_DATA_PATH and CODEX_HOME.
        AppRecipe(
            id: "com.openai.codex",
            bundleIDPrefixes: ["com.openai.codex"],
            arguments: [],
            environment: [
                "CODEX_ELECTRON_USER_DATA_PATH": "${instance}/data",
                "CODEX_HOME": "${instance}/codex-home",
            ],
            createDirectories: ["${instance}/data", "${instance}/codex-home"],
            note: "Codex ignores --user-data-dir but honors its own environment overrides, so the "
                + "instance gets a private data directory (CODEX_ELECTRON_USER_DATA_PATH) and a "
                + "private ~/.codex (CODEX_HOME). It will ask you to sign in on first launch — "
                + "that's the isolation working — and it can run alongside the original.",
            options: []
        ),
        // Claude reads CLAUDE_USER_DATA_DIR itself (it wins over code paths
        // that re-point userData); the flag is kept for older versions. Its
        // built-in Claude Code keeps settings, memory, and history in
        // ~/.claude unless CLAUDE_CONFIG_DIR says otherwise.
        AppRecipe(
            id: "com.anthropic.claudefordesktop",
            bundleIDPrefixes: ["com.anthropic.claudefordesktop"],
            arguments: ["--user-data-dir=${instance}/data"],
            environment: ["CLAUDE_USER_DATA_DIR": "${instance}/data"],
            createDirectories: ["${instance}/data"],
            note: "Claude gets a private data directory (CLAUDE_USER_DATA_DIR), so the instance has "
                + "its own sign-in, chats, and settings. Its log files stay in ~/Library/Logs/Claude: "
                + "Claude opens them before it reads any setting.",
            options: [
                RecipeOption(
                    id: "separate-claude-code",
                    title: "Separate Claude Code settings",
                    detail: "Its own ~/.claude — skills, CLAUDE.md, memory, and history. "
                        + "When off, Claude Code shares them with your other Claude.",
                    defaultEnabled: false,
                    environment: ["CLAUDE_CONFIG_DIR": "${instance}/claude-code"],
                    createDirectories: ["${instance}/claude-code"]
                ),
            ],
            unavoidablyShared: [
                ("Library/Logs/Claude/", "Claude opens its log files by app name before any setting applies"),
            ]
        ),
    ]

    /// Folders under ~/Library/Application Support where apps keep their
    /// default (the original's) profile, for apps where that isn't simply
    /// the app's name. Used to spot leaks and to refuse adopting a live
    /// profile.
    static let knownDataFolders: [String: [String]] = [
        "com.google.Chrome": ["Google/Chrome"],
        "com.google.Chrome.beta": ["Google/Chrome Beta"],
        "com.google.Chrome.dev": ["Google/Chrome Dev"],
        "com.google.Chrome.canary": ["Google/Chrome Canary"],
        "com.brave.Browser": ["BraveSoftware/Brave-Browser"],
        "com.microsoft.edgemac": ["Microsoft Edge"],
        "com.vivaldi.Vivaldi": ["Vivaldi"],
        "org.chromium.Chromium": ["Chromium"],
        "company.thebrowser.Browser": ["Arc"],
        "com.microsoft.VSCode": ["Code"],
        "com.microsoft.VSCodeInsiders": ["Code - Insiders"],
        "com.todesktop.230313mzl4w4u92": ["Cursor"],
        "com.openai.codex": ["Codex", "ChatGPT"],
        "com.anthropic.claudefordesktop": ["Claude"],
        "com.hnc.Discord": ["discord"],
        "md.obsidian": ["obsidian"],
    ]

    /// Folder names (relative to ~/Library/Application Support) that hold
    /// the original app's own profile.
    public static func originalDataFolders(bundleID: String, names: [String]) -> [String] {
        var folders = knownDataFolders[bundleID] ?? []
        for name in names + [bundleID] where !name.isEmpty && !folders.contains(name) {
            folders.append(name)
        }
        return folders
    }

    public static func recipe(for bundleID: String) -> AppRecipe? {
        recipes.first { $0.matches(bundleID: bundleID) }
    }

    /// Best-effort warning for data-dir mode: if `~/.<app>` exists, the app
    /// probably keeps state there, which data-dir flags don't isolate.
    static func dotfileNote(appName: String, home: URL) -> String? {
        let slug = Slug.make(appName)
        guard !slug.isEmpty else { return nil }
        let dotfile = home.appendingPathComponent(".\(slug)")
        guard FileManager.default.fileExists(atPath: dotfile.path) else { return nil }
        return "Heads up: ~/.\(slug) exists. If \(appName) keeps login or session state there, "
            + "data-dir isolation won't cover it — recreate with home mode if the instance "
            + "shares state with the original."
    }

    private static let tccNote =
        "While it runs, macOS sees the instance as the original app (same bundle ID and signature): "
        + "the Dock tile, app switcher, and notifications show the original's name and icon, and privacy "
        + "permissions may be shared with it. Parallex's menu bar shows which instance is in front."

    /// - Parameter enabledOptions: recipe option IDs to turn on; `nil`
    ///   means each option's default.
    public static func plan(
        for app: AppInfo,
        requested: RequestedMode,
        instanceDir: URL,
        sharedItems: [String],
        enabledOptions: Set<String>? = nil,
        clone: Bool = false,
        separateLibrary: Bool = false
    ) -> IsolationPlan {
        var notes: [String] = []
        let libraryNote = "Its own copy keeps everything \(app.name) stores in ~/Library — Application Support, "
            + "caches, web storage — inside the instance, so nothing is shared with the original by accident."

        let resolved: InstanceMode
        let recipe = recipe(for: app.bundleID)

        func expand(_ value: String) -> String {
            value.replacingOccurrences(of: "${instance}", with: instanceDir.path)
        }

        /// The app's own recipe, which data-dir mode means for this app.
        func recipePlan(_ recipe: AppRecipe, extraNotes: [String]) -> IsolationPlan {
            let active = recipe.options.filter { enabledOptions?.contains($0.id) ?? $0.defaultEnabled }
            var environment = recipe.environment
            var directories = recipe.createDirectories
            for option in active {
                environment.merge(option.environment) { _, new in new }
                directories += option.createDirectories.filter { !directories.contains($0) }
            }
            return IsolationPlan(
                mode: .dataDir,
                presetID: recipe.id,
                arguments: recipe.arguments.map(expand),
                createDirectories: directories.map(expand),
                homeOverride: nil,
                homeSymlinks: [],
                environment: environment.mapValues(expand),
                notes: extraNotes + [recipe.note] + (separateLibrary ? [libraryNote] : []) + (clone ? [] : [tccNote]),
                availableOptions: recipe.options,
                enabledOptions: active.map(\.id)
            )
        }

        switch requested {
        case .auto:
            if app.isSandboxed {
                resolved = .launchOnly
                if !clone {
                    notes.append(
                        "\(app.name) is sandboxed (App Store-style): macOS pins its data to "
                        + "~/Library/Containers/\(app.bundleID) no matter what. Turn on “own identity” (clone "
                        + "mode) to give the instance its own container."
                    )
                }
            } else if let recipe {
                return recipePlan(recipe, extraNotes: [])
            } else if app.framework.hasAppAwarePreset {
                resolved = .dataDir
            } else {
                resolved = .home
            }
        case .dataDir:
            if app.isSandboxed {
                notes.append("\(app.name) is sandboxed — data-dir flags usually have no effect on sandboxed apps.")
            }
            if let recipe {
                // Data-dir mode *is* the recipe for apps that have one; a
                // generic flag would be ignored or incomplete.
                return recipePlan(recipe, extraNotes: notes)
            }
            if !app.framework.hasAppAwarePreset {
                notes.append(
                    "No app-aware preset for a \(app.framework.displayName); passing a generic "
                    + "--user-data-dir flag because data-dir mode was requested. Verify it takes effect, "
                    + "or use home mode."
                )
            }
            resolved = .dataDir
        case .home:
            if app.isSandboxed {
                notes.append(
                    "\(app.name) is sandboxed: macOS forces its data into the app container regardless of "
                    + "HOME, so this instance will share data with the original."
                )
            }
            resolved = .home
        case .launchOnly:
            resolved = .launchOnly
        }

        switch resolved {
        case .dataDir:
            let dataDir = instanceDir.appendingPathComponent("data").path
            let arguments: [String]
            let directories: [String]
            switch app.framework {
            case .vscodeFamily:
                let extensionsDir = instanceDir.appendingPathComponent("extensions").path
                arguments = ["--user-data-dir=\(dataDir)", "--extensions-dir=\(extensionsDir)"]
                directories = [dataDir, extensionsDir]
                notes.append(
                    "VS Code-family quirk: if extension search misbehaves in the new profile, the "
                    + "marketplace URL may need to be configured there once."
                )
            case .firefox:
                let profileDir = instanceDir.appendingPathComponent("profile").path
                arguments = ["--no-remote", "--profile", profileDir]
                directories = [profileDir]
            default:
                arguments = ["--user-data-dir=\(dataDir)"]
                directories = [dataDir]
            }
            // Point out home dotfiles the data-dir flags can't isolate (apps
            // with a recipe returned above and explain themselves).
            if let dotNote = dotfileNote(
                   appName: app.name,
                   home: FileManager.default.homeDirectoryForCurrentUser
               ) {
                notes.append(dotNote)
            }
            if separateLibrary {
                notes.append(libraryNote)
            }
            if !clone {
                notes.append(tccNote)
            }
            return IsolationPlan(
                mode: .dataDir,
                presetID: app.framework.hasAppAwarePreset ? app.framework.rawValue : "generic-data-dir",
                arguments: arguments,
                createDirectories: directories,
                homeOverride: nil,
                homeSymlinks: [],
                environment: [:],
                notes: notes
            )

        case .home:
            let homeDir = instanceDir.appendingPathComponent("home").path
            if !sharedItems.isEmpty {
                notes.append(
                    "HOME isolation: \(sharedItems.joined(separator: ", ")) stay shared with your real "
                    + "home; everything else is per-instance."
                )
            }
            if separateLibrary {
                notes.append(libraryNote)
            } else {
                notes.append(
                    "Note: recent macOS versions resolve ~/Library from the user account rather than the "
                    + "HOME variable, so home isolation reliably covers command-line state and dotfiles, "
                    + "but a native app may still write some of its data to your real ~/Library. Turn on "
                    + "“own identity” to keep its Library separate too."
                )
            }
            if !clone {
                notes.append(tccNote)
            }
            return IsolationPlan(
                mode: .home,
                presetID: nil,
                arguments: [],
                createDirectories: [],
                homeOverride: homeDir,
                homeSymlinks: sharedItems,
                environment: [:],
                notes: notes
            )

        case .launchOnly:
            if clone && app.isSandboxed {
                notes.append("The copy's sandbox container is its own, so its data is separate from the original's.")
            } else {
                notes.append(
                    "Launch-only: the instance shares the app's normal data. Apps that enforce a "
                    + "single instance over their data directory may refuse to start a second copy."
                )
            }
            if !clone {
                notes.append(tccNote)
            }
            return IsolationPlan(
                mode: .launchOnly,
                presetID: nil,
                arguments: [],
                createDirectories: [],
                homeOverride: nil,
                homeSymlinks: [],
                environment: [:],
                notes: notes
            )
        }
    }
}
