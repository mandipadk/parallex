import Foundation

/// What an own-identity copy of an app can't do that the original can. A
/// copy is re-signed by Parallex, so anything that needs the developer's own
/// signature (Apple-issued entitlements, installing parts of itself into
/// macOS) stays with the original. Worked out from the app itself, before
/// any copy is made.
public enum CopyLimits {
    public struct Limit: Sendable, Hashable {
        /// A few words, for lists ("No iCloud sync").
        public let short: String
        /// A sentence, for where there's room to explain.
        public let detail: String
    }

    static let systemPartsShort = "Its system extension stays with the original"

    public static func limits(of app: AppInfo) -> [Limit] {
        let keys = Set(app.entitlements.keys)
        func has(_ predicate: (String) -> Bool) -> Bool { keys.contains(where: predicate) }
        var limits: [Limit] = []
        if hasSystemParts(app) {
            limits.append(Limit(
                short: systemPartsShort,
                detail: "\(app.name) installs part of itself into macOS (a system extension: VPN, network filter or "
                    + "driver). Only the original can install it, so that part won't work in the copy."
            ))
        }
        if has({ $0.hasPrefix("com.apple.developer.icloud") || $0.hasPrefix("com.apple.developer.ubiquity") }) {
            limits.append(Limit(
                short: "No iCloud sync",
                detail: "iCloud features won't work in the copy (they need \(app.name)'s own signature)."
            ))
        }
        if has({ $0 == "aps-environment" || $0 == "com.apple.developer.aps-environment" }) {
            limits.append(Limit(
                short: "No push notifications",
                detail: "Notifications \(app.name) delivers by push may not arrive in the copy, especially while it's closed."
            ))
        }
        if keys.contains("com.apple.developer.applesignin") {
            limits.append(Limit(
                short: "No Sign in with Apple",
                detail: "Sign in with Apple won't work in the copy; sign in another way there."
            ))
        }
        if keys.contains("com.apple.developer.associated-domains") {
            limits.append(Limit(
                short: "Its web links open the original",
                detail: "Links to \(app.name)'s website that normally open the app go to the original, not the copy."
            ))
        }
        return limits
    }

    /// Whether the app carries parts that install into macOS itself: system
    /// extensions (network extensions, DriverKit drivers, endpoint security)
    /// or kernel extensions.
    public static func hasSystemParts(_ app: AppInfo) -> Bool {
        let fm = FileManager.default
        let library = app.url.appendingPathComponent("Contents/Library")
        for folder in ["SystemExtensions", "Extensions"] {
            let items = (try? fm.contentsOfDirectory(atPath: library.appendingPathComponent(folder).path)) ?? []
            if items.contains(where: { $0.hasSuffix(".systemextension") || $0.hasSuffix(".dext") || $0.hasSuffix(".kext") }) {
                return true
            }
        }
        return app.entitlements.keys.contains {
            $0 == "com.apple.developer.system-extension.install" || $0.hasPrefix("com.apple.developer.driverkit")
                || $0 == "com.apple.developer.endpoint-security.client"
        }
    }
}
