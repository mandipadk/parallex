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
        /// Parts of it install into macOS (a VPN's network extension, a
        /// driver); a copy runs, but those parts stay with the original.
        case systemParts
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
    /// What the recommended kind of instance can't do that the original can.
    public let cautions: [String]
    /// An instance of this app, at this version, passed an isolation check here.
    public let verified: Bool

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
        let compatibility = Compatibility.load()
        let verified = Verification.load()
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
                apps.append(entry(for: info, compatibility: compatibility, verified: verified))
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
    public static func entry(
        for info: AppInfo,
        compatibility: [String: Compatibility.Record] = [:],
        verified: [String: Verification.Record] = [:]
    ) -> CatalogApp {
        let version = info.infoPlist["CFBundleShortVersionString"] as? String
        let fullVersion = AppCloner.version(of: info.url)
        func make(_ fit: CatalogApp.Fit, _ summary: String, clone: Bool) -> CatalogApp {
            let isVerified = Verification.isVerified(
                bundleID: info.bundleID, version: fullVersion, asCopy: clone, records: verified
            )
            return CatalogApp(
                url: info.url, name: info.name, bundleID: info.bundleID, version: version,
                fit: fit, summary: summary, recommendsClone: clone,
                // Only copies lose what needs the developer's signature.
                // (The system-parts tier says that one in its summary.)
                cautions: clone ? CopyLimits.limits(of: info).map(\.short)
                    .filter { fit != .systemParts || $0 != CopyLimits.systemPartsShort } : [],
                verified: isVerified
            )
        }

        if info.bundleID.hasPrefix("com.apple.") {
            return make(.unsupported, "Part of macOS — Apple's apps can't be duplicated.", clone: false)
        }
        // Learned on this Mac: its copy quit right after opening.
        if Compatibility.refusesCopies(bundleID: info.bundleID, version: fullVersion, records: compatibility) {
            return make(.limited, "Its copy quit right after opening here — it may check its App Store receipt.", clone: false)
        }
        if Presets.recipe(for: info.bundleID) != nil {
            return make(.great, "Separate sign-in and data, tuned for this app.", clone: false)
        }
        if info.framework.hasAppAwarePreset && !info.isSandboxed {
            return make(.great, "Separate sign-in and data, side by side.", clone: false)
        }
        if CopyLimits.hasSystemParts(info) {
            return make(.systemParts, "Its copy runs, but its system extension (VPN, filter or driver) stays with the original.",
                        clone: true)
        }
        if info.isSandboxed {
            let groups = info.entitlements["com.apple.security.application-groups"] as? [String] ?? []
            return make(.ownIdentity, groups.isEmpty
                ? "Its own copy gets its own data container."
                : "Its own copy gets its own containers, including shared ones.", clone: true)
        }
        // Sign-ins it keeps in the keychain aren't separated yet, so the
        // promise is the Library, where everything else lives.
        return make(.ownIdentity, "Its own copy gets its own Library, so its data stays separate.", clone: true)
    }
}
