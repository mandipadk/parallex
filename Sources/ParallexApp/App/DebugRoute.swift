#if DEBUG
import SwiftUI

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

    /// `createWeb:<address>`: the create flow's website step, filled in.
    static var webCreate: String? {
        guard let value, value.hasPrefix("createWeb") else { return nil }
        return value.hasPrefix("createWeb:") ? String(value.dropFirst("createWeb:".count)) : ""
    }

    static var showsMenuPanel: Bool { value == "panel" }
    static var showsSettings: Bool { value == "settings" || value?.hasPrefix("settings:") == true }
    /// `settings:links` opens Settings on that tab.
    static var settingsTab: String? {
        guard let value, value.hasPrefix("settings:") else { return nil }
        return String(value.dropFirst("settings:".count))
    }
    /// `PARALLEX_UI_SCROLL=center|bottom` scrolls the detail pane.
    static var scrollAnchor: UnitPoint? {
        switch ProcessInfo.processInfo.environment["PARALLEX_UI_SCROLL"] {
        case "center": .center
        case "bottom": .bottom
        default: nil
        }
    }

    static var showsWhatsNew: Bool { value == "whatsnew" }

    /// `update:available`, `update:downloading`, `update:current`, `update:failed`.
    static var updatePhase: String? {
        guard let value, value.hasPrefix("update:") else { return nil }
        return String(value.dropFirst("update:".count))
    }
}
#endif
