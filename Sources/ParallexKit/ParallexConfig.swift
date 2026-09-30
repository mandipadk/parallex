import Foundation

/// Shared between the CLI and the generic launcher: the names of the keys in a
/// wrapper bundle's Info.plist that carry the launch configuration.
///
/// The CLI writes these when assembling a wrapper; the launcher reads them from
/// `Bundle.main` at launch. Nothing else should hardcode these strings.
public enum ParallexConfig {
    public static let version = "1.2.0"

    /// Top-level Info.plist key holding the launcher configuration dictionary.
    public static let rootKey = "Parallex"

    public enum Key {
        /// Absolute path to the target app's main executable (required).
        public static let targetBinary = "TargetBinary"
        /// Absolute path to the target .app bundle. The launcher re-reads the
        /// bundle's CFBundleExecutable at launch, so a renamed executable
        /// doesn't break the wrapper.
        public static let targetApp = "TargetApp"
        /// The target's bundle identifier. If the target app was moved, the
        /// launcher finds it again through Launch Services by this ID.
        public static let targetBundleID = "TargetBundleID"
        /// Arguments passed to the target binary (optional).
        public static let arguments = "Arguments"
        /// Extra environment variables set before exec (optional, string→string).
        public static let environment = "Environment"
        /// If present, HOME is pointed at this directory before exec (optional).
        public static let homeOverride = "HomeOverride"
        /// Paths relative to the real home that are symlinked into the
        /// instance home so they stay shared (optional, used with HomeOverride).
        public static let homeSymlinks = "HomeSymlinks"
        /// Directories the launcher creates (mkdir -p) before exec (optional).
        public static let createDirectories = "CreateDirectories"
        /// Links the launcher (re)creates before each launch, alias → target:
        /// short stand-ins for paths an app can't use at their full length
        /// (VS Code's socket must fit in 104 bytes).
        public static let links = "Links"
        /// Settings shared with the original app, synced before each
        /// launch: [{From, To, Keys}] (see `SettingsSync`).
        public static let settingsSync = "SettingsSync"
        /// The instance's slug, linking the wrapper back to its manifest.
        public static let slug = "Slug"
        /// The instance's home folder, presented to the app (an own-identity
        /// copy) as the user's home: the copy loads Parallex's home-redirect
        /// library, so everything it keeps in ~/Library stays in the instance.
        public static let redirectHome = "RedirectHome"
        /// The home-redirect library to load (absolute path, in Parallex's
        /// support folder so it outlives any one copy).
        public static let redirectLibrary = "RedirectLibrary"
        /// Where the copy was built; the redirect is scoped to it, so a moved
        /// copy needs rebuilding.
        public static let redirectScope = "RedirectScope"
        /// Present when the redirected home mirrors your real home: every
        /// item in it is linked in except `Library` and these (relative
        /// paths, at most two levels, e.g. `.vscode`, `.config/zed`), which
        /// stay the instance's own. The copy then also sees that home as
        /// `$HOME`.
        public static let redirectPrivate = "RedirectPrivate"
        /// Appended to the copy's "<App> Safe Storage" keychain items' names,
        /// so it has its own encryption key instead of the original's.
        public static let keychainSuffix = "KeychainSuffix"
        /// "… Safe Storage" names left alone: other apps' keys (a browser
        /// copy importing from Chrome reads Chrome's).
        public static let keychainKeep = "KeychainKeep"
        /// File the launcher writes its PID to before exec. Because execv
        /// keeps the PID, this is the running instance's PID — the reliable
        /// way to find instances (their Launch Services identity reverts to
        /// the target's after exec, and process env isn't readable on
        /// modern macOS). Format: see `PidFileRecord`.
        public static let pidFile = "PidFile"
        /// An own-identity copy's own keychain (a file in its instance
        /// folder, its password beside it): the launcher makes and unlocks
        /// it, and the copy keeps every password item there (see
        /// `InstanceKeychain`).
        public static let instanceKeychain = "InstanceKeychain"
        /// The copy's app loads the home-redirect library itself (a load
        /// command Parallex added to it), not only through
        /// DYLD_INSERT_LIBRARIES, so it keeps its own Library even if
        /// macOS stops honoring that variable.
        public static let homeLibraryLinked = "HomeLibraryLinked"
        /// The copy keeps its "<App> Safe Storage" key in its own keychain
        /// too (copies made with their own keychain); older copies keep
        /// theirs, renamed, in the login keychain, where their data's key is.
        public static let safeStorageInKeychain = "SafeStorageInKeychain"
        /// Guard: the original app's data, which nothing in the copy may
        /// open, create, rename or remove (absolute paths; a folder ends in
        /// "/"). See recorder.c in ParallexHome.
        public static let guardedPaths = "GuardedPaths"
        /// Loopback ports the app finds a running copy of itself on, which
        /// in the copy are ports of its own: "<app's>:<copy's>" (see ports.c
        /// in ParallexHome).
        public static let loopbackPorts = "LoopbackPorts"
        /// The Parallex version that built this instance. A copy's
        /// CFBundleShortVersionString is its app's, so this is what says
        /// whether it has the current launcher.
        public static let builtWith = "BuiltWith"
    }

    /// Own-Library separation needs macOS to load Parallex's library into the
    /// copy. Before opening one, the launcher runs itself with this argument
    /// and the library requested, to see whether macOS still allows that.
    public static let separationProbeArgument = "--parallex-separation-probe"

    /// A copy refreshed while it ran waits in the instance folder until it
    /// can take the running copy's place: `<instance>/staged/copy.staged`
    /// (not `.app`, so macOS never takes it for an app) with the instance
    /// record it comes with. Parallex puts it in place when the copy quits;
    /// the copy's launcher does, if the copy is opened first.
    public static let stagingFolder = "staged"
    public static let stagedCopyName = "copy.staged"

    /// Written into the instance folder (next to its home) when the probe
    /// found separation unavailable, so the app can explain and offer a way
    /// out; removed as soon as a probe succeeds.
    public static let separationUnavailableMarker = "separation-unavailable"
}

/// The pid file's contents: the PID on the first line, since 0.5 the
/// executable the launcher exec'd on the second, and since 1.1 the process's
/// start time on the third. The executable path rejects a recycled PID even
/// when the target app was moved after the instance was created; the start
/// time rejects one that the same app got again (a wrapper's executable *is*
/// the original app's, so after a quit the original could otherwise pass for
/// the instance). Older launchers write less.
public struct PidFileRecord: Equatable, Sendable {
    public var pid: Int32
    public var executablePath: String?
    /// When the process started ("seconds.microseconds"); `execv` keeps it.
    public var started: String?

    public init(pid: Int32, executablePath: String?, started: String? = nil) {
        self.pid = pid
        self.executablePath = executablePath
        self.started = started
    }

    public init?(parsing text: String) {
        // Trim by hand: paths can contain inner spaces ("Application
        // Support"), so only the ends.
        let lines = text.split(whereSeparator: \.isNewline).map { line -> String in
            var slice = Substring(line)
            while slice.first?.isWhitespace == true { slice = slice.dropFirst() }
            while slice.last?.isWhitespace == true { slice = slice.dropLast() }
            return String(slice)
        }
        guard let first = lines.first, let pid = Int32(first), pid > 0 else {
            return nil
        }
        self.pid = pid
        self.executablePath = lines.count > 1 && !lines[1].isEmpty ? lines[1] : nil
        self.started = lines.count > 2 && !lines[2].isEmpty ? lines[2] : nil
    }

    public var serialized: String {
        [String(pid), executablePath ?? "", started ?? ""]
            .reversed().drop { $0.isEmpty }.reversed()
            .map { $0 + "\n" }.joined()
    }

    /// A process's start time, as recorded in `started`.
    public static func startTime(of pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
    }

    /// The recorded process, if it's still the one the launcher became:
    /// alive, running `executablePath` (or `expectedExecutable` for records
    /// without one), and started when recorded.
    public func liveProcess(expectedExecutable: String) -> Int32? {
        guard kill(pid, 0) == 0 || errno == EPERM else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        // The kernel reports the resolved path (/private/tmp/… for /tmp/…).
        let actual = URL(fileURLWithPath: String(decoding: buffer[..<Int(length)], as: UTF8.self))
            .resolvingSymlinksInPath().path
        let expected = URL(fileURLWithPath: executablePath ?? expectedExecutable).resolvingSymlinksInPath().path
        guard actual == expected else { return nil }
        if let started, Self.startTime(of: pid) != started {
            return nil
        }
        return pid
    }
}

/// Processes started from inside an instance (a terminal in an instance's
/// editor, an app opened from its shell) inherit its environment — including
/// the variables that point the app at the instance's data. Launching another
/// app with those would silently open *this* instance's data, so they're
/// dropped before launching anything else.
public enum InheritedIsolation {
    /// Whether an inherited variable belongs to some instance's isolation.
    public static func matches(key: String, value: String, instancesRoot: String?) -> Bool {
        if key == "PARALLEX_INSTANCE" {
            return true
        }
        // Only whole-value paths into an instance; a list like PATH that
        // merely includes one is left alone (dropping it would break more).
        guard value.hasPrefix("/"), !value.contains(":") else {
            return false
        }
        if let instancesRoot, value.hasPrefix(instancesRoot + "/") {
            return true
        }
        return value.contains("/Parallex/instances/")
    }
}
