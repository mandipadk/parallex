import Foundation

/// Well-known locations. All instance data lives under one support root so it
/// is easy to find, back up, or nuke. PARALLEX_HOME overrides the root for
/// tests and for users who want their instance data elsewhere.
public enum Paths {
    public static var supportRoot: URL {
        if let override = ProcessInfo.processInfo.environment["PARALLEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parallex", isDirectory: true)
    }

    public static var instancesRoot: URL {
        supportRoot.appendingPathComponent("instances", isDirectory: true)
    }

    /// Per-instance directory: holds the manifest plus the instance's
    /// `data/`, `extensions/`, `profile/`, or `home/` depending on mode.
    public static func instanceDir(slug: String) -> URL {
        instancesRoot.appendingPathComponent(slug, isDirectory: true)
    }

    /// PID file the launcher writes before exec (see `Running`).
    public static func pidFile(slug: String) -> URL {
        instanceDir(slug: slug).appendingPathComponent("instance.pid")
    }

    /// Render a path — or an argument embedding paths, like
    /// `--user-data-dir=<home>/…` — with the home directory shown as `~`.
    public static func abbreviate(_ text: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if text == home {
            return "~"
        }
        return text.replacingOccurrences(of: home + "/", with: "~/")
    }
}
