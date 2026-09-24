import Foundation

/// Throwaway instances: for a one-off sign-in or a quick test. Once one has
/// run and quit, it's done, and Parallex moves it and its data to the Trash
/// (so it can still be recovered from there).
///
/// "Has run" is read from the pid file the launcher writes before it becomes
/// the app. Only a pid file written since the instance became a throwaway
/// counts (not one left from before, or from a run that was already going),
/// and only once it's a few seconds old (the launcher is about to become the
/// app). Copies that start without the launcher (sandboxed ones) write no
/// pid file, so they can't be throwaways.
public enum Throwaway {
    /// How old a launch must be before its end counts as the end.
    static let settle: TimeInterval = 15

    /// Keeps when an instance became a throwaway: set when it becomes one,
    /// kept while it stays one, cleared when it stops.
    static func normalize(_ settings: inout InstanceSettings, was previous: InstanceSettings?, now: Date = Date()) {
        guard settings.throwaway == true else {
            settings.throwaway = nil
            settings.throwawaySince = nil
            return
        }
        settings.throwawaySince = previous?.throwaway == true ? (previous?.throwawaySince ?? now) : now
    }

    /// Whether this kind of instance can be a throwaway.
    public static func isPossible(for manifest: InstanceManifest) -> Bool {
        manifest.clone?.usesLauncher != false
    }

    /// When it was last opened as a throwaway, if it has been.
    public static func lastLaunch(of manifest: InstanceManifest) -> Date? {
        let settings = manifest.effectiveSettings
        guard settings.throwaway == true, let since = settings.throwawaySince, isPossible(for: manifest),
              let written = (try? FileManager.default.attributesOfItem(atPath: Paths.pidFile(slug: manifest.slug).path))?[.modificationDate] as? Date,
              written >= since
        else { return nil }
        return written
    }

    /// Opened since it became a throwaway, and not running now.
    public static func isFinished(_ manifest: InstanceManifest, now: Date = Date()) -> Bool {
        guard let launched = lastLaunch(of: manifest), now.timeIntervalSince(launched) >= settle,
              !Running.isRunning(manifest)
        else { return false }
        // Nothing still running from inside it either (a copy's helpers,
        // or a launch that's just starting).
        // (/private/tmp and /tmp are the same place, spelled either way.)
        func plain(_ path: String) -> String { path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path }
        let bundle = plain(URL(fileURLWithPath: manifest.wrapperPath).standardizedFileURL.path) + "/"
        return !IsolationCheck.allPIDs().contains { pid in
            Running.executablePath(of: pid).map { plain($0).hasPrefix(bundle) } ?? false
        }
    }

    public static func finished(_ manifests: [InstanceManifest]) -> [InstanceManifest] {
        manifests.filter { isFinished($0) }
    }

    /// Move a finished throwaway to the Trash, looking once more first (it
    /// may have been opened again). Nil when it isn't finished after all.
    public static func clear(_ manifest: InstanceManifest) throws -> RemoveResult? {
        guard let fresh = InstanceStore.load(slug: manifest.slug), isFinished(fresh) else { return nil }
        return try InstanceRemover.remove(fresh, keepData: false)
    }
}
