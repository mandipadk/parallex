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

/// Whether macOS actually loads the home-redirect library into code signed
/// like this copy: the launcher is signed the same way as the app, so it
/// runs itself as the test (see the probe mode at the top of Main). The
/// environment must already request the library.
enum SeparationProbe {
    case loaded, notLoaded, unknown

    static func run() -> SeparationProbe {
        guard let executable = Bundle.main.executablePath else { return .unknown }
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(executable), strdup(ParallexConfig.separationProbeArgument), nil,
        ]
        defer { argv.forEach { free($0) } }
        guard posix_spawn(&pid, executable, nil, nil, argv, environ) == 0 else { return .unknown }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { return .unknown }
        }
        // Exited normally (not signalled): 0 = loaded, 3 = not loaded.
        guard status & 0x7f == 0 else { return .unknown }
        switch (status >> 8) & 0xff {
        case 0: return .loaded
        case 3: return .notLoaded
        default: return .unknown
        }
    }

    /// In the probe process: is the library among the loaded images?
    static func libraryIsLoaded() -> Bool {
        for index in 0..<_dyld_image_count() {
            if let name = _dyld_get_image_name(index), String(cString: name).hasSuffix("/libparallexhome.dylib") {
                return true
            }
        }
        return false
    }
}

// MARK: - Main

// Probe mode: report whether the redirect library was loaded, and nothing else.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == ParallexConfig.separationProbeArgument {
    exit(SeparationProbe.libraryIsLoaded() ? 0 : 3)
}

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
// 1b. Short aliases for long paths (macOS empties temporary folders, so
//     they're made again each launch). Only ever replaces a link.
for (alias, target) in config[ParallexConfig.Key.links] as? [String: String] ?? [:] {
    let fm = FileManager.default
    if let current = try? fm.destinationOfSymbolicLink(atPath: alias) {
        // Only a link of your own: in a folder others could write to,
        // someone else's link could later be pointed elsewhere.
        var info = stat()
        let ownLink = lstat(alias, &info) == 0 && info.st_uid == getuid()
        if current == target, ownLink { continue }
        guard ownLink else {
            fail("Something that isn't yours is in the way at \(alias). Remove it, then open the instance again.")
        }
        try? fm.removeItem(atPath: alias)
    } else if (try? fm.attributesOfItem(atPath: alias)) != nil {
        fail("Something that isn't Parallex's is in the way at \(alias). Move it, then open the instance again.")
    }
    do {
        try fm.createDirectory(atPath: (alias as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: alias, withDestinationPath: target)
    } catch {
        fail("Could not prepare this instance's data folder (\(alias)): \(error.localizedDescription)")
    }
}

// 1c. Settings shared with the original (like Claude's MCP servers). Not
//     fatal: the instance opens with what it had.
for item in (config[ParallexConfig.Key.settingsSync] as? [Any] ?? []).compactMap(SettingsSync.Item.init(plist:)) {
    do {
        try SettingsSync.apply(item)
    } catch {
        FileHandle.standardError.write(Data("parallex-launcher: couldn't share settings with \(item.to): \(error)\n".utf8))
    }
}

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
    // Mirrored home: it looks like yours except for the app's own folders,
    // and the copy sees it as $HOME too.
    if let privateItems = config[ParallexConfig.Key.redirectPrivate] as? [String] {
        HomeMirror.sync(
            home: URL(fileURLWithPath: redirectHome, isDirectory: true),
            realHome: URL(fileURLWithPath: realHome, isDirectory: true),
            privateItems: privateItems
        )
        setenv("PARALLEX_HOME_ENV", "1", 1)
    } else {
        unsetenv("PARALLEX_HOME_ENV")
    }
    if let suffix = config[ParallexConfig.Key.keychainSuffix] as? String {
        setenv("PARALLEX_KEYCHAIN_SUFFIX", suffix, 1)
        setenv("PARALLEX_KEYCHAIN_KEEP", (config[ParallexConfig.Key.keychainKeep] as? [String] ?? []).joined(separator: "\n"), 1)
    } else {
        unsetenv("PARALLEX_KEYCHAIN_SUFFIX")
        unsetenv("PARALLEX_KEYCHAIN_KEEP")
    }
    setenv("PARALLEX_HOME_REDIRECT", redirectHome, 1)
    setenv("PARALLEX_HOME_SCOPE", bundle, 1)
    let existing = (ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"] ?? "")
        .split(separator: ":").map(String.init)
        .filter { !$0.isEmpty && !$0.hasSuffix("/libparallexhome.dylib") }
    setenv("DYLD_INSERT_LIBRARIES", ([library] + existing).joined(separator: ":"), 1)

    // Opening it without the library would put its data in the original's
    // folders, so don't — say why, and leave a note for Parallex to explain.
    let marker = URL(fileURLWithPath: redirectHome).deletingLastPathComponent()
        .appendingPathComponent(ParallexConfig.separationUnavailableMarker)
    switch SeparationProbe.run() {
    case .loaded:
        try? FileManager.default.removeItem(at: marker)
    case .notLoaded:
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        try? Data(version.utf8).write(to: marker, options: .atomic)
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "This instance"
        fail("""
            macOS didn't let Parallex give “\(app)” a Library of its own, so it wasn't opened: \
            it would have used the original app's settings and sign-ins.

            Open Parallex to use it as a plain copy, sharing the original's data, \
            or try again after updating Parallex or macOS.
            """)
    case .unknown:
        // Couldn't tell; the isolation check will look once it's running.
        break
    }
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

// 5. Become the target. A web link this launch was given (Parallex Links
//    opening a link in a browser instance that isn't running) follows the
//    instance's own arguments. Nothing else is passed on: a flag from
//    whoever launched the wrapper could undo its isolation.
let passedOn = CommandLine.arguments.dropFirst().filter { argument in
    guard let url = URL(string: argument), let scheme = url.scheme?.lowercased() else { return false }
    return (scheme == "http" || scheme == "https") && url.host != nil
}
let arguments = (config[ParallexConfig.Key.arguments] as? [String] ?? []) + passedOn
log.info("launching \(targetBinary, privacy: .public) with \(arguments.count) argument(s)")
execTarget(targetBinary, arguments: arguments)
