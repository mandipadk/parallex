import AppKit
import Foundation
import ParallexKit

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

        // The name an app shows (what `parallex apps` lists), when it
        // differs from its file name: "Code" is Visual Studio Code.app.
        if !expanded.contains("/"), let found = locate(displayName: expanded) {
            return found
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

    /// An installed app whose displayed name matches (ignoring case), in the
    /// folders the catalog scans; never a Parallex wrapper.
    static func locate(displayName name: String, directories: [URL] = AppCatalog.defaultDirectories) -> URL? {
        let wanted = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        let fm = FileManager.default
        for directory in directories {
            let apps = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for app in apps.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where app.pathExtension == "app" {
                guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                      info[ParallexConfig.rootKey] == nil
                else { continue }
                let names = [info["CFBundleDisplayName"], info["CFBundleName"]].compactMap { $0 as? String }
                if names.contains(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) {
                    return app
                }
            }
        }
        return nil
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
