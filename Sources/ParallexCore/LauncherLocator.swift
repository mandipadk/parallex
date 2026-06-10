import Foundation

/// Finds the generic `parallex-launcher` binary that gets copied into every
/// wrapper. It ships alongside the CLI binary, or inside the GUI app's
/// Resources; PARALLEX_LAUNCHER overrides for development and tests.
enum LauncherLocator {
    static func locate() throws -> URL {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["PARALLEX_LAUNCHER"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }
        // GUI app: embedded at Parallex.app/Contents/Resources/parallex-launcher.
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("parallex-launcher"))
        }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let binDir = executable.deletingLastPathComponent()
            candidates.append(binDir.appendingPathComponent("parallex-launcher"))
            // Homebrew-style layout: bin/parallex + libexec/parallex-launcher.
            candidates.append(
                binDir.deletingLastPathComponent()
                    .appendingPathComponent("libexec/parallex-launcher")
            )
        }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        let searched = candidates.map { "  \($0.path)" }.joined(separator: "\n")
        throw ParallexError("""
        Could not find the 'parallex-launcher' binary. Looked in:
        \(searched)
        Build it with `swift build` (it is part of this package) or reinstall Parallex.
        """)
    }
}
