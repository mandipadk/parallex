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
}

public enum Presets {
    /// Items symlinked from the real home into an instance home so user files
    /// stay shared while app data (~/Library) is isolated.
    public static let defaultSharedItems = [
        "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures",
        ".gitconfig", ".ssh",
    ]

    /// Apps where framework detection picks the wrong recipe. Some Electron
    /// apps pin their data directory in code (app.setPath('userData', …)), so
    /// --user-data-dir does nothing — but they often honor their own
    /// environment variables instead. `${instance}` in values expands to the
    /// instance directory. Keyed by bundle ID prefix.
    struct AppOverride {
        let bundleIDPrefix: String
        let mode: InstanceMode
        /// Environment recipe implementing the isolation.
        let environment: [String: String]
        let createDirectories: [String]
        let note: String
    }

    static let appOverrides: [AppOverride] = [
        // Codex calls app.setPath('userData', …) — its userData (and the
        // single-instance lock inside it) is pinned in code, and its session
        // lives in ~/.codex. Both have env overrides in Codex's own code:
        // CODEX_ELECTRON_USER_DATA_PATH and CODEX_HOME.
        AppOverride(
            bundleIDPrefix: "com.openai.codex",
            mode: .dataDir,
            environment: [
                "CODEX_ELECTRON_USER_DATA_PATH": "${instance}/data",
                "CODEX_HOME": "${instance}/codex-home",
            ],
            createDirectories: ["${instance}/data", "${instance}/codex-home"],
            note: "Codex ignores --user-data-dir but honors its own environment overrides, so the "
                + "instance gets a private data directory (CODEX_ELECTRON_USER_DATA_PATH) and a "
                + "private ~/.codex (CODEX_HOME). It will ask you to sign in on first launch — "
                + "that's the isolation working — and it can run alongside the original."
        ),
    ]

    static func override(for bundleID: String) -> AppOverride? {
        appOverrides.first { bundleID == $0.bundleIDPrefix || bundleID.hasPrefix($0.bundleIDPrefix + ".") }
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
        "macOS permissions (notifications, camera, screen recording, …) are tracked per bundle ID — "
        + "the instance will prompt again on first use."

    public static func plan(
        for app: AppInfo,
        requested: RequestedMode,
        instanceDir: URL,
        sharedItems: [String]
    ) -> IsolationPlan {
        var notes: [String] = []
        let resolved: InstanceMode

        func expand(_ value: String) -> String {
            value.replacingOccurrences(of: "${instance}", with: instanceDir.path)
        }

        switch requested {
        case .auto:
            if app.isSandboxed {
                resolved = .launchOnly
                notes.append(
                    "\(app.name) is sandboxed (App Store-style): macOS pins its data to "
                    + "~/Library/Containers/\(app.bundleID) no matter what, so Parallex can only give it a "
                    + "separate identity, not separate data."
                )
            } else if let override = override(for: app.bundleID) {
                // Per-app recipe: isolation via the app's own env overrides.
                return IsolationPlan(
                    mode: override.mode,
                    presetID: override.bundleIDPrefix,
                    arguments: [],
                    createDirectories: override.createDirectories.map(expand),
                    homeOverride: nil,
                    homeSymlinks: [],
                    environment: override.environment.mapValues(expand),
                    notes: [override.note, tccNote]
                )
            } else if app.framework.hasAppAwarePreset {
                resolved = .dataDir
            } else {
                resolved = .home
            }
        case .dataDir:
            if app.isSandboxed {
                notes.append("\(app.name) is sandboxed — data-dir flags usually have no effect on sandboxed apps.")
            }
            if override(for: app.bundleID) != nil {
                notes.append(
                    "Heads up: \(app.name) is known to ignore data-dir flags — use auto mode so "
                    + "Parallex can apply its per-app recipe instead."
                )
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
            // Overridden apps already explain themselves; for the rest, point
            // out home dotfiles the data-dir flags can't isolate.
            if override(for: app.bundleID) == nil,
               let dotNote = dotfileNote(
                   appName: app.name,
                   home: FileManager.default.homeDirectoryForCurrentUser
               ) {
                notes.append(dotNote)
            }
            notes.append(tccNote)
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
            notes.append(
                "Note: recent macOS versions resolve ~/Library from the user account rather than the "
                + "HOME variable, so home isolation reliably covers command-line state and dotfiles, "
                + "but a native app may still write some of its data to your real ~/Library."
            )
            notes.append(tccNote)
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
            notes.append(
                "Launch-only: the instance shares the app's normal data. Apps that enforce a "
                + "single instance over their data directory may refuse to start a second copy."
            )
            notes.append(tccNote)
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
