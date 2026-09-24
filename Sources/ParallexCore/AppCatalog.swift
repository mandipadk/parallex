import Foundation

/// The apps installed on this Mac, and how well each can be duplicated —
/// what the onboarding and the New Instance gallery offer.
public struct CatalogApp: Sendable, Identifiable, Hashable {
    /// How well Parallex can give this app a second, separate copy.
    public enum Fit: Int, Sendable, Comparable, Hashable {
        /// A recipe or framework flags give each instance its own data.
        case great
        /// Native app: data separation works best as its own-identity copy.
        case ownIdentity
        /// App Store app: an own-identity copy gets its own container, but
        /// some data lives in containers shared across the developer's apps.
        case limited
        /// Apple's own apps (and Parallex's) can't be duplicated.
        case unsupported

        public static func < (lhs: Fit, rhs: Fit) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let url: URL
    public let name: String
    public let bundleID: String
    public let version: String?
    public let fit: Fit
    /// One line on what an instance of this app gets.
    public let summary: String
    /// Whether an own-identity copy is the better way to duplicate it.
    public let recommendsClone: Bool

    public var id: String { url.path }
}

public enum AppCatalog {
    public static var defaultDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    /// Installed apps, best fits first, then by name. Skips Parallex's own
    /// bundles and anything that isn't a readable app bundle.
    public static func scan(directories: [URL] = defaultDirectories) -> [CatalogApp] {
        let fm = FileManager.default
        var seen = Set<String>()
        var apps: [CatalogApp] = []
        for directory in directories {
            let entries = (try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            for url in entries where url.pathExtension == "app" {
                guard let info = try? AppInspector.inspect(url),
                      !info.isParallexWrapper,
                      !info.bundleID.hasPrefix("com.parallex."),
                      seen.insert(info.bundleID).inserted
                else {
                    continue
                }
                apps.append(entry(for: info))
            }
        }
        // Best fit first; within a tier, apps with a tuned recipe lead.
        return apps.sorted {
            if $0.fit != $1.fit { return $0.fit < $1.fit }
            let lhsTuned = Presets.recipe(for: $0.bundleID) != nil
            let rhsTuned = Presets.recipe(for: $1.bundleID) != nil
            if lhsTuned != rhsTuned { return lhsTuned }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Classify one app.
    public static func entry(for info: AppInfo) -> CatalogApp {
        let version = info.infoPlist["CFBundleShortVersionString"] as? String
        func make(_ fit: CatalogApp.Fit, _ summary: String, clone: Bool) -> CatalogApp {
            CatalogApp(
                url: info.url, name: info.name, bundleID: info.bundleID, version: version,
                fit: fit, summary: summary, recommendsClone: clone
            )
        }

        if info.bundleID.hasPrefix("com.apple.") {
            return make(.unsupported, "Part of macOS — Apple's apps can't be duplicated.", clone: false)
        }
        if Presets.recipe(for: info.bundleID) != nil {
            return make(.great, "Separate sign-in and data, tuned for this app.", clone: false)
        }
        if info.framework.hasAppAwarePreset && !info.isSandboxed {
            return make(.great, "Separate sign-in and data, side by side.", clone: false)
        }
        if info.isSandboxed {
            let entitlements = AppInspector.signingInfo(of: info.url).entitlements ?? [:]
            let groups = entitlements["com.apple.security.application-groups"] as? [String] ?? []
            return make(.ownIdentity, groups.isEmpty
                ? "Its own copy gets its own data container."
                : "Its own copy gets its own containers, including shared ones.", clone: true)
        }
        return make(.ownIdentity, "Its own copy gets separate sign-in and data.", clone: true)
    }
}
