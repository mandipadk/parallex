/// Shared between the CLI and the generic launcher: the names of the keys in a
/// wrapper bundle's Info.plist that carry the launch configuration.
///
/// The CLI writes these when assembling a wrapper; the launcher reads them from
/// `Bundle.main` at launch. Nothing else should hardcode these strings.
public enum ParallexConfig {
    public static let version = "0.7.0"

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
        /// The instance's slug, linking the wrapper back to its manifest.
        public static let slug = "Slug"
        /// File the launcher writes its PID to before exec. Because execv
        /// keeps the PID, this is the running instance's PID — the reliable
        /// way to find instances (their Launch Services identity reverts to
        /// the target's after exec, and process env isn't readable on
        /// modern macOS). Format: see `PidFileRecord`.
        public static let pidFile = "PidFile"
    }
}

/// The pid file's contents: the PID on the first line and, since 0.5, the
/// executable the launcher exec'd on the second. The executable path lets
/// liveness checks reject a recycled PID even when the target app was moved
/// after the instance was created. Older launchers write only the PID.
public struct PidFileRecord: Equatable, Sendable {
    public var pid: Int32
    public var executablePath: String?

    public init(pid: Int32, executablePath: String?) {
        self.pid = pid
        self.executablePath = executablePath
    }

    public init?(parsing text: String) {
        // No Foundation here (the launcher stays lean): trim by hand. Paths
        // can contain inner spaces ("Application Support"), so only the ends.
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
    }

    public var serialized: String {
        executablePath.map { "\(pid)\n\($0)\n" } ?? "\(pid)\n"
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
