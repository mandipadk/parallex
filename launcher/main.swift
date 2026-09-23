// Parallex generic launcher.
//
// This binary lives at Contents/MacOS/launcher inside every wrapper .app that
// `parallex create` emits. It reads its configuration from the wrapper's own
// Info.plist (the `Parallex` dictionary), prepares the isolated environment,
// and then replaces itself with the target binary via execv().
//
// execv — not spawn-and-exit — keeps the PID, so the pid file written just
// before exec names the running instance for its whole lifetime. Note that
// the exec'd app checks in with Launch Services under its *own* identity
// (bundle ID, name, Dock tile): macOS derives identity from the executable,
// and hardened-runtime apps ignore the environment overrides that could
// change that. Parallex tracks instances by PID instead.

import AppKit
import Foundation
import ParallexKit
import os

let log = Logger(subsystem: "com.parallex.launcher", category: "launch")

/// Report a fatal problem and exit. When launched from Finder/Dock (no TTY on
/// stderr) the message is also shown in a dialog so it doesn't vanish into the
/// void. PARALLEX_LAUNCHER_NO_UI=1 suppresses the dialog (used by tests).
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("parallex-launcher: \(message)\n").utf8))
    log.error("\(message, privacy: .public)")
    let suppressUI = ProcessInfo.processInfo.environment["PARALLEX_LAUNCHER_NO_UI"] == "1"
    if isatty(STDERR_FILENO) == 0 && !suppressUI {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        let title = name.map { "“\($0)” could not start" } ?? "Parallex launcher error"
        var response: CFOptionFlags = 0
        CFUserNotificationDisplayAlert(
            30, CFOptionFlags(kCFUserNotificationStopAlertLevel),
            nil, nil, nil,
            title as CFString, message as CFString,
            "OK" as CFString, nil, nil, &response
        )
    }
    exit(1)
}

/// First-run (and idempotent every-run) scaffolding for HOME-override mode:
/// create the Library skeleton inside the instance home and symlink selected
/// items back to the real home so they stay shared across instances.
func scaffoldHome(at instanceHome: String, realHome: String, symlinks: [String]) {
    let fm = FileManager.default
    let home = URL(fileURLWithPath: instanceHome, isDirectory: true)
    for subdir in ["Library/Preferences", "Library/Application Support", "Library/Caches", "Library/Logs"] {
        try? fm.createDirectory(at: home.appendingPathComponent(subdir), withIntermediateDirectories: true)
    }
    for item in symlinks {
        let source = URL(fileURLWithPath: realHome).appendingPathComponent(item)
        let link = home.appendingPathComponent(item)
        guard fm.fileExists(atPath: source.path) else { continue }
        // attributesOfItem does not follow symlinks: anything already at the
        // link path (file, dir, or dangling link) means we leave it alone.
        guard (try? fm.attributesOfItem(atPath: link.path)) == nil else { continue }
        try? fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: link, withDestinationURL: source)
    }
}

/// Where the target's main executable lives right now. Wrappers record the
/// executable path at create time, but apps get moved and executables get
/// renamed by updates — so prefer what the target bundle says today, then the
/// recorded path, then wherever Launch Services now finds the bundle ID.
func resolveTargetBinary(config: [String: Any]) -> String? {
    let fm = FileManager.default
    func executable(inBundle path: String) -> String? {
        let bundle = URL(fileURLWithPath: path, isDirectory: true)
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let name = plist["CFBundleExecutable"] as? String
        else {
            return nil
        }
        let candidate = bundle.appendingPathComponent("Contents/MacOS").appendingPathComponent(name).path
        return fm.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    if let targetApp = config[ParallexConfig.Key.targetApp] as? String,
       let found = executable(inBundle: targetApp) {
        return found
    }
    if let recorded = config[ParallexConfig.Key.targetBinary] as? String,
       fm.isExecutableFile(atPath: recorded) {
        return recorded
    }
    if let bundleID = config[ParallexConfig.Key.targetBundleID] as? String {
        for url in NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID) {
            // Never resolve to another Parallex wrapper of the same app.
            if let bundle = Bundle(url: url), bundle.object(forInfoDictionaryKey: ParallexConfig.rootKey) != nil {
                continue
            }
            if let found = executable(inBundle: url.path) {
                return found
            }
        }
    }
    return nil
}

/// If this instance is already running, return its PID. Launch Services
/// can't tell us (a running instance carries the target's identity, not the
/// wrapper's), so a Dock or Spotlight click on a running wrapper lands here
/// again. Starting a second copy would lose the app's single-instance race,
/// overwrite the pid file, and leave a phantom Dock icon.
func runningInstancePID(pidFile: String, expectedExecutable: String) -> pid_t? {
    guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
          let record = PidFileRecord(parsing: text),
          record.pid != getpid()
    else {
        return nil
    }
    guard kill(record.pid, 0) == 0 || errno == EPERM else {
        return nil
    }
    var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let length = proc_pidpath(record.pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    let path = String(decoding: buffer[..<Int(length)], as: UTF8.self)
    // The kernel reports the resolved path (/private/tmp/… for /tmp/…).
    let expected = URL(fileURLWithPath: record.executablePath ?? expectedExecutable).resolvingSymlinksInPath().path
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == expected ? record.pid : nil
}

/// Replace this process with the target binary, keeping our PID.
func execTarget(_ path: String, arguments: [String]) -> Never {
    var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path)]
    argv.append(contentsOf: arguments.map { strdup($0) })
    argv.append(nil)
    execv(path, argv)
    fail("Could not execute \(path): \(String(cString: strerror(errno)))")
}

// MARK: - Main

guard let config = Bundle.main.object(forInfoDictionaryKey: ParallexConfig.rootKey) as? [String: Any] else {
    fail("""
    This wrapper's Info.plist has no '\(ParallexConfig.rootKey)' configuration. \
    The bundle is damaged — re-create the instance with `parallex create`.
    """)
}
guard config[ParallexConfig.Key.targetBinary] is String || config[ParallexConfig.Key.targetApp] is String else {
    fail("The '\(ParallexConfig.rootKey)' configuration names no target app. Re-create the instance with `parallex create`.")
}
guard let targetBinary = resolveTargetBinary(config: config) else {
    let expected = config[ParallexConfig.Key.targetApp] as? String
        ?? config[ParallexConfig.Key.targetBinary] as? String ?? "?"
    fail("""
    The original app can't be found:

    \(expected)

    It may have been moved, renamed, or uninstalled. Reinstall it, or \
    repair this instance in Parallex.
    """)
}
// A clone's main executable is this launcher; exec'ing ourselves would loop.
if let own = Bundle.main.executableURL?.resolvingSymlinksInPath().path,
   URL(fileURLWithPath: targetBinary).resolvingSymlinksInPath().path == own {
    fail("This instance's configuration points at its own launcher. Repair it in Parallex.")
}
let pidFile = config[ParallexConfig.Key.pidFile] as? String

// 0. Already running? Bring it forward instead of starting a second copy.
if let pidFile, let running = runningInstancePID(pidFile: pidFile, expectedExecutable: targetBinary) {
    log.info("instance already running as pid \(running, privacy: .public); activating it")
    NSRunningApplication(processIdentifier: running)?.activate(options: [.activateAllWindows])
    exit(0)
}

// Drop isolation variables inherited from another instance (this launcher
// may have been started from inside one); this instance sets its own below.
do {
    let instancesRoot = pidFile.map {
        URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path
    }
    for (key, value) in ProcessInfo.processInfo.environment
    where InheritedIsolation.matches(key: key, value: value, instancesRoot: instancesRoot) {
        if key == "HOME" {
            if let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir {
                setenv("HOME", home, 1)
            }
        } else {
            unsetenv(key)
        }
    }
}

// 1. Pre-create the directories the instance needs (e.g. the user-data dir).
//    A missing data directory silently costs isolation — many apps fall back
//    to their default location — so failure here is fatal.
for directory in config[ParallexConfig.Key.createDirectories] as? [String] ?? [] {
    do {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    } catch {
        fail("""
        Could not create the instance's data directory, so it would not be isolated:

        \(directory)

        \(error.localizedDescription)
        """)
    }
}

// 2. Optional HOME override — the generic isolation tier for non-Electron apps.
if let instanceHome = config[ParallexConfig.Key.homeOverride] as? String {
    let realHome = ProcessInfo.processInfo.environment["HOME"]
        ?? FileManager.default.homeDirectoryForCurrentUser.path
    scaffoldHome(
        at: instanceHome,
        realHome: realHome,
        symlinks: config[ParallexConfig.Key.homeSymlinks] as? [String] ?? []
    )
    setenv("HOME", instanceHome, 1)
}

// 3. Extra environment variables from the config.
for (key, value) in config[ParallexConfig.Key.environment] as? [String: String] ?? [:] {
    setenv(key, value, 1)
}

// 3b. Own-identity copy with its own Library: load the home-redirect library
//     into the app (only processes inside this bundle act on it). Set after
//     the extra environment, so nothing there can undo it.
if let redirectHome = config[ParallexConfig.Key.redirectHome] as? String,
   let library = config[ParallexConfig.Key.redirectLibrary] as? String,
   let scope = config[ParallexConfig.Key.redirectScope] as? String {
    let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().path
    // Its services carry the scope recorded at build time; somewhere else,
    // they'd quietly use the real Library.
    guard URL(fileURLWithPath: scope).resolvingSymlinksInPath().path == bundle else {
        fail("This instance's app was moved from \(scope). Open Parallex and repair it, then open it again.")
    }
    guard FileManager.default.fileExists(atPath: library) else {
        fail("Part of Parallex this instance needs is missing (\(library)). Open Parallex and repair the instance.")
    }
    let realHome = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } }
        ?? FileManager.default.homeDirectoryForCurrentUser.path
    scaffoldHome(
        at: redirectHome,
        realHome: realHome,
        symlinks: config[ParallexConfig.Key.homeSymlinks] as? [String] ?? []
    )
    setenv("PARALLEX_HOME_REDIRECT", redirectHome, 1)
    setenv("PARALLEX_HOME_SCOPE", bundle, 1)
    let existing = (ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"] ?? "")
        .split(separator: ":").map(String.init)
        .filter { !$0.isEmpty && !$0.hasSuffix("/libparallexhome.dylib") }
    setenv("DYLD_INSERT_LIBRARIES", ([library] + existing).joined(separator: ":"), 1)
}

// 4. Record our PID and the executable we're about to become. execv keeps
//    the PID, so this identifies the instance's process for its whole run.
if let pidFile {
    let url = URL(fileURLWithPath: pidFile)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let record = PidFileRecord(pid: getpid(), executablePath: targetBinary)
    try? Data(record.serialized.utf8).write(to: url, options: .atomic)
}

// 5. Become the target.
let arguments = config[ParallexConfig.Key.arguments] as? [String] ?? []
log.info("launching \(targetBinary, privacy: .public) with \(arguments.count) argument(s)")
execTarget(targetBinary, arguments: arguments)
