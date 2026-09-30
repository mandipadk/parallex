import Foundation
import ParallexKit

/// Settings, not accounts: an editor copy can use the original's settings,
/// keybindings, snippets and extensions, kept in step because they're the
/// same files (its home links them to yours), while its sign-ins, open
/// projects and everything else stay its own. What's shareable is known per
/// app; the copy's own versions are set aside while shared, and back when
/// sharing stops.
public enum SharedSettings {
    static func vscodeLike(_ folder: String, _ dotfolder: String) -> [String] {
        let user = "Library/Application Support/\(folder)/User"
        return ["\(user)/settings.json", "\(user)/keybindings.json", "\(user)/snippets", "\(dotfolder)/extensions"]
    }

    static let known: [String: [String]] = [
        "com.microsoft.VSCode": vscodeLike("Code", ".vscode"),
        "com.microsoft.VSCodeInsiders": vscodeLike("Code - Insiders", ".vscode-insiders"),
        "com.vscodium": vscodeLike("VSCodium", ".vscode-oss"),
        "com.todesktop.230313mzl4w4u92": vscodeLike("Cursor", ".cursor"),
        "com.exafunction.windsurf": vscodeLike("Windsurf", ".windsurf"),
        "dev.zed.Zed": [".config/zed/settings.json", ".config/zed/keymap.json", ".config/zed/themes", ".local/share/zed/extensions"],
        "dev.zed.Zed-Preview": [".config/zed/settings.json", ".config/zed/keymap.json", ".config/zed/themes", ".local/share/zed/extensions"],
    ]

    /// What of `bundleID`'s can be shared (relative to home). For tests,
    /// PARALLEX_SHAREABLE_FOR ("<bundle id>=<item>,<item>") adds some.
    public static func shareable(for bundleID: String) -> [String] {
        var items = known[bundleID] ?? []
        if let extra = ProcessInfo.processInfo.environment["PARALLEX_SHAREABLE_FOR"] {
            let parts = extra.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0] == bundleID {
                items += parts[1].split(separator: ",").map(String.init)
            }
        }
        return items.filter { item in
            let parts = item.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            return !parts.isEmpty && parts.allSatisfy(OriginalData.isPlainName)
        }
    }

    /// Stop sharing `items` in a copy's `home`: its links to yours go, and
    /// what it had before comes back. Nothing of yours is touched.
    public static func unlink(_ items: [String], home: URL, realHome: URL) {
        for item in items {
            SettingsLinks.unlink(item, home: home, realHome: realHome)
        }
    }
}
