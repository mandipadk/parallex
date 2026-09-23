import AppKit
import Darwin
import ParallexKit

/// Live-process checks for instances.
///
/// Identity subtlety: after the wrapper execs the target binary, the app's
/// Launch Services check-in re-derives its identity from the executable path —
/// the running process registers under the *target's* bundle ID, not the
/// wrapper's, so bundle-ID lookups miss running instances. And modern macOS
/// doesn't let us read other processes' environments. Instead, the launcher
/// writes its PID to `<instance dir>/instance.pid` right before exec — execv
/// keeps the PID, so that file names the instance's process for its whole
/// lifetime. Liveness = PID alive + its executable is the expected target
/// binary (guards against PID reuse and stale files).
public enum Running {
    /// PID of the running instance, if any.
    public static func processID(instanceSlug: String, targetBinary: String) -> pid_t? {
        let pidFile = Paths.pidFile(slug: instanceSlug)
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let record = PidFileRecord(parsing: text)
        else {
            return nil
        }
        let pid = record.pid
        // kill(pid, 0): delivery check only. ESRCH → gone; EPERM → exists.
        guard kill(pid, 0) == 0 || errno == EPERM else {
            return nil
        }
        // Launchers since 0.5 record the executable they exec'd (which can
        // differ from the manifest's if the target app moved).
        // The kernel reports the resolved path (/private/tmp/… for /tmp/…).
        let expected = URL(fileURLWithPath: record.executablePath ?? targetBinary).resolvingSymlinksInPath().path
        guard let actual = executablePath(of: pid),
              URL(fileURLWithPath: actual).resolvingSymlinksInPath().path == expected
        else {
            return nil
        }
        return pid
    }

    public static func isRunning(instanceSlug: String, targetBinary: String) -> Bool {
        processID(instanceSlug: instanceSlug, targetBinary: targetBinary) != nil
    }

    /// PID of a running instance. Clones run under their own bundle ID, so
    /// when there's no pid file (sandboxed clones start without the
    /// launcher) they're found through Launch Services.
    public static func processID(of manifest: InstanceManifest) -> pid_t? {
        if let pid = processID(instanceSlug: manifest.slug, targetBinary: manifest.targetBinary) {
            return pid
        }
        guard let clone = manifest.clone else { return nil }
        nonisolated(unsafe) var found: pid_t?
        onMainThread {
            found = NSRunningApplication.runningApplications(withBundleIdentifier: clone.bundleIdentifier)
                .first?.processIdentifier
        }
        return found
    }

    public static func isRunning(_ manifest: InstanceManifest) -> Bool {
        processID(of: manifest) != nil
    }

    /// Legacy bundle-ID check; only sees apps that didn't re-register their
    /// identity after exec. Prefer `isRunning(instanceSlug:targetBinary:)`.
    public static func isRunning(bundleIdentifier: String) -> Bool {
        nonisolated(unsafe) var running = false
        onMainThread {
            running = !NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .isEmpty
        }
        return running
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer[..<Int(length)], as: UTF8.self)
    }
}
