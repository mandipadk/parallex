import Foundation

/// Finds the generic `parallex-launcher` binary that gets copied into every
/// wrapper. It ships alongside the CLI binary, or inside the GUI app's
/// Resources; PARALLEX_LAUNCHER overrides for development and tests.
public enum LauncherLocator {
    static func locate() throws -> URL {
        try locate(helper: "parallex-launcher", override: "PARALLEX_LAUNCHER")
    }

    /// The home-redirect library copied into own-identity copies.
    public static func locateHomeLibrary() throws -> URL {
        try locate(helper: "libparallexhome.dylib", override: "PARALLEX_HOME_LIBRARY", executable: false)
    }

    /// The link router binary ("Parallex Links"), shipped the same way.
    public static func locateRouter() throws -> URL {
        try locate(helper: "parallex-router", override: "PARALLEX_ROUTER")
    }

    static func locate(helper name: String, override variable: String, executable: Bool = true) throws -> URL {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment[variable], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }
        // GUI app: embedded at Parallex.app/Contents/Resources/<name>.
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(name))
        }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let binDir = executable.deletingLastPathComponent()
            candidates.append(binDir.appendingPathComponent(name))
            // Homebrew-style layout: bin/parallex + libexec/<name>.
            candidates.append(
                binDir.deletingLastPathComponent()
                    .appendingPathComponent("libexec/\(name)")
            )
        }
        let fm = FileManager.default
        for candidate in candidates
        where executable ? fm.isExecutableFile(atPath: candidate.path) : fm.fileExists(atPath: candidate.path) {
            return candidate
        }
        let searched = candidates.map { "  \($0.path)" }.joined(separator: "\n")
        throw ParallexError("""
        Could not find the '\(name)' binary. Looked in:
        \(searched)
        Build it with `swift build` (it is part of this package) or reinstall Parallex.
        """)
    }
}
