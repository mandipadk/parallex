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
    return record.liveProcess(expectedExecutable: expectedExecutable)
}

/// Held from the "already running?" check until the exec, so two launches
/// at once (login restore and Parallex opening it, say) can't both start
/// the app: the second waits, then finds the first running. Opened
/// close-on-exec, so the running app never holds it.
func holdLaunchLock(pidFile: String) {
    let descriptor = open(pidFile + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
    guard descriptor >= 0 else { return }
    while flock(descriptor, LOCK_EX) != 0 && errno == EINTR {}
}

/// A refresh of this copy that Parallex built while it ran (see
/// `ParallexConfig.stagingFolder`): put it in place of this copy and start
/// over from it. Only the same copy (same identity, same instance) with the
/// same name, place and settings as the instance has now is taken; anything
/// off, and the copy opens as it is (Parallex sorts the refresh out).
func installStagedRefresh(pidFile: String, config: [String: Any]) {
    let fm = FileManager.default
    let instanceDir = URL(fileURLWithPath: pidFile).deletingLastPathComponent()
    let staging = instanceDir.appendingPathComponent(ParallexConfig.stagingFolder)
    let staged = staging.appendingPathComponent(ParallexConfig.stagedCopyName)
    let record = staging.appendingPathComponent("instance.json")
    guard fm.fileExists(atPath: staged.path), fm.fileExists(atPath: record.path),
          let data = try? Data(contentsOf: staged.appendingPathComponent("Contents/Info.plist")),
          let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
          info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
          let stagedConfig = info[ParallexConfig.rootKey] as? [String: Any],
          let slug = config[ParallexConfig.Key.slug] as? String,
          stagedConfig[ParallexConfig.Key.slug] as? String == slug,
          let stagedRecord = jsonObject(at: record),
          let liveRecord = jsonObject(at: instanceDir.appendingPathComponent("instance.json")),
          stagedRecord["name"] as? String == liveRecord["name"] as? String,
          stagedRecord["wrapperPath"] as? String == liveRecord["wrapperPath"] as? String,
          (stagedRecord["settings"] as? NSDictionary) == (liveRecord["settings"] as? NSDictionary),
          !anythingElseRuns(inside: Bundle.main.bundleURL)
    else {
        return
    }
    // Moving to another version of its app: first its data as the version
    // it leaves left it, as Parallex does, so it can go back.
    let liveClone = liveRecord["clone"] as? [String: Any]
    if let from = liveClone?["sourceVersion"] as? String, !from.isEmpty,
       let to = (stagedRecord["clone"] as? [String: Any])?["sourceVersion"] as? String, from != to,
       liveRecord["redirectedHome"] is String,
       (liveRecord["settings"] as? [String: Any])?["keepPreviousVersion"] as? Bool != false {
        let now = Date()
        let id = SnapshotWriter.uniqueID(for: now, in: instanceDir.appendingPathComponent(SnapshotWriter.folderName))
        let app = URL(fileURLWithPath: liveRecord["targetApp"] as? String ?? "App").deletingPathExtension().lastPathComponent
        let snapshot: [String: Any] = [
            "id": id, "date": ISO8601DateFormatter().string(from: now), "label": "Before moving to \(app) \(to)",
            "reason": "before-refresh", "appVersion": from,
        ]
        if let record = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) {
            try? SnapshotWriter.capture(
                instance: instanceDir, id: id, record: record, copyID: liveClone?["bundleIdentifier"] as? String
            )
        }
    }
    let own = Bundle.main.bundleURL
    let previous = staging.appendingPathComponent("previous-\(UUID().uuidString).app")
    // Renames only (the refresh sits on the same disk); if either fails,
    // everything stays as it was.
    guard rename(own.path, previous.path) == 0 else { return }
    guard rename(staged.path, own.path) == 0 else {
        _ = rename(previous.path, own.path)
        return
    }
    _ = rename(record.path, instanceDir.appendingPathComponent("instance.json").path)
    log.info("installed the refreshed copy; starting over from it")
    let launcher = own.appendingPathComponent("Contents/MacOS/parallex-launcher").path
    var argv: [UnsafeMutablePointer<CChar>?] = [strdup(launcher)]
    argv.append(contentsOf: CommandLine.arguments.dropFirst().map { strdup($0) })
    argv.append(nil)
    execv(launcher, argv)
    fail("Could not start the refreshed copy: \(String(cString: strerror(errno)))")
}

/// Whether a process other than this one runs from inside `bundle` (a
/// helper that outlived the app, say).
func anythingElseRuns(inside bundle: URL) -> Bool {
    let prefix = bundle.resolvingSymlinksInPath().path + "/"
    let estimate = proc_listallpids(nil, 0)
    guard estimate > 0 else { return false }
    var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
    for pid in pids.prefix(Int(max(count, 0))) where pid > 0 && pid != getpid() {
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { continue }
        let path = URL(fileURLWithPath: String(decoding: buffer[..<Int(length)], as: UTF8.self)).resolvingSymlinksInPath().path
        if path.hasPrefix(prefix) {
            return true
        }
    }
    return false
}

func jsonObject(at url: URL) -> [String: Any]? {
    (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
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
if let pidFile {
    try? FileManager.default.createDirectory(
        at: URL(fileURLWithPath: pidFile).deletingLastPathComponent(), withIntermediateDirectories: true
    )
    holdLaunchLock(pidFile: pidFile)
}
if let pidFile, let running = runningInstancePID(pidFile: pidFile, expectedExecutable: targetBinary) {
    log.info("instance already running as pid \(running, privacy: .public); activating it")
    NSRunningApplication(processIdentifier: running)?.activate(options: [.activateAllWindows])
    exit(0)
}

// 0b. A refresh waiting to take over (this copy wasn't running when it
//     could): install it and start over from it.
if let pidFile, config[ParallexConfig.Key.redirectScope] != nil || Bundle.main.executableURL?.lastPathComponent == "parallex-launcher" {
    installStagedRefresh(pidFile: pidFile, config: config)
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

// 1d. The copy's own keychain, ready before the app asks for anything in
//     it. Before any HOME override: the keychain APIs find your keychains
//     through $HOME. If it can't be made or unlocked, the copy doesn't
//     open: it would find, and could overwrite, the original's sign-ins.
if let keychain = config[ParallexConfig.Key.instanceKeychain] as? String {
    guard InstanceKeychain.prepare(path: keychain) else {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "This instance"
        fail("""
            “\(name)” keeps its sign-ins in a keychain of its own, and that keychain couldn't be opened \
            (\(keychain)), so it wasn't opened: it would have used your keychain instead.

            Open Parallex and try again, or turn off Separate keychain for it to share yours.
            """)
    }
    setenv("PARALLEX_INSTANCE_KEYCHAIN", keychain, 1)
    if config[ParallexConfig.Key.safeStorageInKeychain] as? Bool == true {
        setenv("PARALLEX_SAFE_STORAGE_OWN", "1", 1)
    } else {
        unsetenv("PARALLEX_SAFE_STORAGE_OWN")
    }
} else {
    unsetenv("PARALLEX_INSTANCE_KEYCHAIN")
    unsetenv("PARALLEX_SAFE_STORAGE_OWN")
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
    // The flight recorder's log (recorder.c) starts with the first launch,
    // so "watched since" counts from then even while nothing is noted.
    let accessLog = URL(fileURLWithPath: redirectHome).deletingLastPathComponent().appendingPathComponent("access.log").path
    if !FileManager.default.fileExists(atPath: accessLog) {
        FileManager.default.createFile(atPath: accessLog, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    // Guard: the original's data is off limits (recorder.c).
    if let guarded = config[ParallexConfig.Key.guardedPaths] as? [String], !guarded.isEmpty {
        setenv("PARALLEX_GUARD", guarded.joined(separator: "\n"), 1)
    } else {
        unsetenv("PARALLEX_GUARD")
    }
    // The original's settings, shared on purpose (an editor's): the home
    // links to yours, and stops when sharing does.
    SettingsLinks.sync(
        config[ParallexConfig.Key.sharedSettings] as? [String] ?? [],
        home: URL(fileURLWithPath: redirectHome, isDirectory: true),
        realHome: URL(fileURLWithPath: realHome, isDirectory: true),
        instance: URL(fileURLWithPath: redirectHome).deletingLastPathComponent()
    )
    // In a workspace with a persona: the shells and tools the copy starts
    // get the persona's home (home.c), brought up to date here.
    let personaMarker = URL(fileURLWithPath: redirectHome).deletingLastPathComponent().appendingPathComponent("persona.json")
    if let data = try? Data(contentsOf: personaMarker),
       let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let personaHome = marker["home"] as? String, personaHome.hasPrefix("/") {
        let items = marker["items"] as? [String] ?? []
        HomeMirror.sync(
            home: URL(fileURLWithPath: personaHome, isDirectory: true),
            realHome: URL(fileURLWithPath: realHome, isDirectory: true), privateItems: items, linkLibrary: true
        )
        setenv("PARALLEX_CHILD_HOME", personaHome, 1)
        if let workspace = marker["workspace"] as? String {
            setenv("PARALLEX_WORKSPACE", workspace, 1)
        }
    } else {
        unsetenv("PARALLEX_CHILD_HOME")
        unsetenv("PARALLEX_WORKSPACE")
    }
    // Ports the app finds itself on are the copy's own (ports.c).
    if let ports = config[ParallexConfig.Key.loopbackPorts] as? [String], !ports.isEmpty {
        setenv("PARALLEX_LOOPBACK_PORTS", ports.joined(separator: ","), 1)
    } else {
        unsetenv("PARALLEX_LOOPBACK_PORTS")
    }
    setenv("PARALLEX_HOME_REDIRECT", redirectHome, 1)
    setenv("PARALLEX_HOME_SCOPE", bundle, 1)
    let existing = (ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"] ?? "")
        .split(separator: ":").map(String.init)
        .filter { !$0.isEmpty && !$0.hasSuffix("/libparallexhome.dylib") }
    setenv("DYLD_INSERT_LIBRARIES", ([library] + existing).joined(separator: ":"), 1)

    // Opening it without the library would put its data in the original's
    // folders, so don't — say why, and leave a note for Parallex to explain.
    // (Not needed when the app loads the library by itself.)
    let marker = URL(fileURLWithPath: redirectHome).deletingLastPathComponent()
        .appendingPathComponent(ParallexConfig.separationUnavailableMarker)
    let linked = config[ParallexConfig.Key.homeLibraryLinked] as? Bool == true
    switch linked ? .loaded : SeparationProbe.run() {
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
    let record = PidFileRecord(
        pid: getpid(), executablePath: targetBinary, started: PidFileRecord.startTime(of: getpid())
    )
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
// 4b. Its workspace's proxy (persona.json, kept by Parallex in the instance
//     folder): the usual variables for everything, and Chromium's switch
//     for an app built on it.
var proxyArguments: [String] = []
if let pidFile,
   let data = try? Data(contentsOf: URL(fileURLWithPath: pidFile).deletingLastPathComponent().appendingPathComponent("persona.json")),
   let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let proxy = marker["proxy"] as? String, proxy.contains("://"), !proxy.contains(where: \.isWhitespace), !proxy.contains("@") {
    for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] {
        setenv(name, proxy, 1)
        setenv(name.lowercased(), proxy, 1)
    }
    // This Mac's own addresses stay direct (a local server, say).
    if getenv("NO_PROXY") == nil && getenv("no_proxy") == nil {
        setenv("NO_PROXY", "localhost,127.0.0.1,::1", 1)
        setenv("no_proxy", "localhost,127.0.0.1,::1", 1)
    }
    let bundles = [Bundle.main.bundleURL.path] + [config[ParallexConfig.Key.targetApp] as? String].compactMap { $0 }
    let chromium = bundles.contains { bundle in
        let frameworks = (try? FileManager.default.contentsOfDirectory(atPath: bundle + "/Contents/Frameworks")) ?? []
        return frameworks.contains { $0 == "Electron Framework.framework" || $0 == "Chromium Embedded Framework.framework"
            || $0.hasSuffix(" Framework.framework") && ($0.contains("Chrome") || $0.contains("Chromium") || $0.contains("Brave")
                || $0.contains("Edge") || $0.contains("Vivaldi") || $0.contains("Opera")) }
    }
    if chromium {
        // Chromium knows socks5 (which resolves names through the proxy
        // already), not socks5h.
        let chromiumProxy = proxy.hasPrefix("socks5h://") ? "socks5://" + proxy.dropFirst("socks5h://".count) : proxy
        proxyArguments = ["--proxy-server=\(chromiumProxy)"]
    }
}
let arguments = (config[ParallexConfig.Key.arguments] as? [String] ?? []) + proxyArguments + passedOn
log.info("launching \(targetBinary, privacy: .public) with \(arguments.count) argument(s)")
execTarget(targetBinary, arguments: arguments)
