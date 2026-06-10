/// Shared between the CLI and the generic launcher: the names of the keys in a
/// wrapper bundle's Info.plist that carry the launch configuration.
///
/// The CLI writes these when assembling a wrapper; the launcher reads them from
/// `Bundle.main` at launch. Nothing else should hardcode these strings.
public enum ParallexConfig {
    public static let version = "0.4.0"

    /// Top-level Info.plist key holding the launcher configuration dictionary.
    public static let rootKey = "Parallex"

    public enum Key {
        /// Absolute path to the target app's main executable (required).
        public static let targetBinary = "TargetBinary"
        /// Absolute path to the target .app bundle (informational, used by `list`/`doctor`).
        public static let targetApp = "TargetApp"
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
        /// modern macOS).
        public static let pidFile = "PidFile"
    }
}
