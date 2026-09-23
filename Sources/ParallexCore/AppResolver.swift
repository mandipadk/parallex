import AppKit
import Foundation

/// Resolve a user-supplied app reference to an .app bundle on disk. Accepts a
/// path, a bare app name ("Claude"), or a bundle identifier.
public enum AppResolver {
    public static func resolve(_ input: String) throws -> URL {
        let fm = FileManager.default
        let expanded = (input as NSString).expandingTildeInPath

        var candidates = [expanded]
        if !expanded.contains("/") {
            let name = expanded.hasSuffix(".app") ? String(expanded.dropLast(4)) : expanded
            candidates += [
                "/Applications/\(name).app",
                "\(NSHomeDirectory())/Applications/\(name).app",
                "/System/Applications/\(name).app",
            ]
        }
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDirectory),
               isDirectory.boolValue,
               candidate.hasSuffix(".app") {
                return URL(fileURLWithPath: candidate, isDirectory: true)
            }
        }

        // Last resort: treat dotted, non-path input as a bundle identifier.
        if input.contains("."), !input.contains("/"), !input.hasSuffix(".app"),
           let found = locate(bundleID: input) {
            return found
        }

        throw ParallexError("""
        Could not find an app for '\(input)'. Pass a path like /Applications/Claude.app, \
        an app name like 'Claude', or a bundle identifier.
        """)
    }

    /// Find an installed app by bundle ID, skipping Parallex wrappers (which
    /// don't share the target's ID, but be safe against hand-made copies).
    public static func locate(bundleID: String) -> URL? {
        nonisolated(unsafe) var candidates: [URL] = []
        onMainThread {
            candidates = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
        }
        return candidates.first { !BundleBuilder.isParallexWrapper($0) }
    }
}
