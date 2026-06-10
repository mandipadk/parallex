// Parallex generic launcher.
//
// This binary lives at Contents/MacOS/launcher inside every wrapper .app that
// `parallex create` emits. It reads its configuration from the wrapper's own
// Info.plist (the `Parallex` dictionary), prepares the isolated environment,
// and then replaces itself with the target binary via execv().
//
// execv — not spawn-and-exit — is the load-bearing detail: the process keeps
// the PID that Launch Services registered for the wrapper bundle, which is
// what gives the running instance the wrapper's Dock icon, name, and identity.

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
guard let targetBinary = config[ParallexConfig.Key.targetBinary] as? String else {
    fail("The '\(ParallexConfig.rootKey)' configuration is missing '\(ParallexConfig.Key.targetBinary)'. Re-create the instance with `parallex create`.")
}
guard FileManager.default.isExecutableFile(atPath: targetBinary) else {
    fail("""
    The target binary no longer exists:

    \(targetBinary)

    The original app may have been moved, renamed, or uninstalled. \
    Re-create this instance with `parallex create`.
    """)
}

// 1. Pre-create any directories the instance needs (e.g. the user-data dir).
for directory in config[ParallexConfig.Key.createDirectories] as? [String] ?? [] {
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
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

// 4. Record our PID. execv keeps it, so this is the instance's PID for the
//    whole run — `parallex list` and the app use it for liveness checks.
if let pidFile = config[ParallexConfig.Key.pidFile] as? String {
    let url = URL(fileURLWithPath: pidFile)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try? Data("\(getpid())".utf8).write(to: url, options: .atomic)
}

// 5. Become the target.
let arguments = config[ParallexConfig.Key.arguments] as? [String] ?? []
log.info("launching \(targetBinary, privacy: .public) with \(arguments.count) argument(s)")
execTarget(targetBinary, arguments: arguments)
