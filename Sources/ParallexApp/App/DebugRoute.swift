#if DEBUG
import Foundation

/// Development only: open a specific screen at launch for visual review,
/// e.g. `PARALLEX_UI_ROUTE=onboarding:2` or `PARALLEX_UI_ROUTE=create`.
enum DebugRoute {
    static var value: String? { ProcessInfo.processInfo.environment["PARALLEX_UI_ROUTE"] }

    static var onboardingPage: Int? {
        guard let value, value.hasPrefix("onboarding:") else { return nil }
        return Int(value.dropFirst("onboarding:".count))
    }

    static var selectedInstance: String? {
        guard let value, value.hasPrefix("instance:") else { return nil }
        return String(value.dropFirst("instance:".count))
    }

    static var createApp: String? {
        guard let value, value.hasPrefix("create"), !value.hasPrefix("createInline") else { return nil }
        return value.hasPrefix("create:") ? String(value.dropFirst("create:".count)) : ""
    }

    /// The create flow as window content (sheets can't be captured alone).
    static var inlineCreate: String? {
        guard let value, value.hasPrefix("createInline") else { return nil }
        return value.hasPrefix("createInline:") ? String(value.dropFirst("createInline:".count)) : ""
    }

    static var showsMenuPanel: Bool { value == "panel" }
    static var showsSettings: Bool { value == "settings" }
}
#endif
