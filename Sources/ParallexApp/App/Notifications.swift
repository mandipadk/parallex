import AppKit
import ParallexCore
import UserNotifications

/// The few notifications worth interrupting for: a running copy that's
/// behind its app, an instance whose app is gone, an automatic repair that
/// failed, and a Parallex update. Each fires once per change of state — the
/// last state notified is remembered, so relaunching Parallex doesn't repeat
/// itself — and each carries the action that resolves it.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Category {
        static let copyBehind = "copy-behind"
        static let needsAttention = "needs-attention"
        static let update = "update"
    }

    enum Action {
        static let restart = "restart"
        static let install = "install"
    }

    private let model: AppModel
    /// Opens the main window on an instance, or the update sheet.
    var onShowInstance: ((String) -> Void)?
    var onShowUpdate: (() -> Void)?
    var onInstallUpdate: (() -> Void)?

    private static let notifiedKey = "notifiedStates"
    private var authorized: Bool?

    init(model: AppModel) {
        self.model = model
        super.init()
        guard Self.available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Category.copyBehind,
                actions: [UNNotificationAction(identifier: Action.restart, title: "Restart Now")],
                intentIdentifiers: []
            ),
            UNNotificationCategory(identifier: Category.needsAttention, actions: [], intentIdentifiers: []),
            UNNotificationCategory(
                identifier: Category.update,
                actions: [UNNotificationAction(identifier: Action.install, title: "Update")],
                intentIdentifiers: []
            ),
        ])
        track()
    }

    /// Notifications need a real app bundle (not a bare `swift run` binary).
    static var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: PreferenceKey.notifyProblems) as? Bool ?? true
    }

    // MARK: - Instance states

    private func track() {
        withObservationTracking {
            evaluate(model.entries, failures: model.maintenanceFailures, leaking: model.leaking)
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
    }

    /// The notification-worthy state of each instance, as a comparable key.
    private func evaluate(_ entries: [InstanceEntry], failures: Set<String>, leaking: Set<String>) {
        var notified = UserDefaults.standard.dictionary(forKey: Self.notifiedKey) as? [String: String] ?? [:]
        var changed = false
        for entry in entries {
            let failed = failures.contains(entry.id)
            let key = "instance." + entry.id
            guard let state = Self.state(of: entry, failed: failed, leaking: leaking.contains(entry.id)) else {
                // Forget what was said only once the instance is healthy
                // again — not merely because a copy stopped running or this
                // is a new session (a repair that fails every launch should
                // be reported once, not every launch).
                if entry.status.problems.isEmpty, !failed, !leaking.contains(entry.id), notified[key] != nil {
                    notified[key] = nil
                    changed = true
                }
                continue
            }
            guard state.key != notified[key] else { continue }
            notified[key] = state.key
            changed = true
            if Self.enabled {
                post(id: key, title: state.title, body: state.body, category: state.category, slug: entry.id)
            }
        }
        // Forget removed instances.
        let live = Set(entries.map { "instance." + $0.id })
        for key in notified.keys where key.hasPrefix("instance.") && !live.contains(key) {
            notified[key] = nil
            changed = true
        }
        if changed {
            UserDefaults.standard.set(notified, forKey: Self.notifiedKey)
        }
    }

    struct State {
        var key: String
        var title: String
        var body: String
        var category: String
    }

    static func state(of entry: InstanceEntry, failed: Bool, leaking: Bool = false) -> State? {
        let problems = entry.status.problems
        if leaking {
            return State(
                key: "leaking",
                title: "\(entry.name) is using \(entry.targetName)'s data",
                body: "Its isolation check found files it shouldn't share. Open it in Parallex to see which.",
                category: Category.needsAttention
            )
        }
        if problems.contains(.targetMissing) {
            return State(
                key: "missing",
                title: "\(entry.name) can't find \(entry.targetName)",
                body: "Reinstall \(entry.targetName), or show Parallex where it is now.",
                category: Category.needsAttention
            )
        }
        if failed {
            return State(
                key: "repair-failed",
                title: "Couldn't update \(entry.name)",
                body: "Parallex tried to bring it up to date and hit a problem. Open it in Parallex to see why.",
                category: Category.needsAttention
            )
        }
        if entry.running, entry.isClone {
            for problem in problems {
                if case .cloneOutdated(_, let original) = problem {
                    return State(
                        key: "behind-" + original,
                        title: "\(entry.name) is behind \(entry.targetName)",
                        body: "\(entry.targetName) updated to \(original). Restart \(entry.name) to bring its copy up to date.",
                        category: Category.copyBehind
                    )
                }
            }
        }
        return nil
    }

    // MARK: - Updates

    /// Announce an available update, once per version.
    func notifyUpdate(version: String) {
        var notified = UserDefaults.standard.dictionary(forKey: Self.notifiedKey) as? [String: String] ?? [:]
        guard notified["update"] != version else { return }
        notified["update"] = version
        UserDefaults.standard.set(notified, forKey: Self.notifiedKey)
        guard UserDefaults.standard.object(forKey: PreferenceKey.notifyUpdates) as? Bool ?? true else { return }
        post(
            id: "update",
            title: "Parallex \(version) is available",
            body: "See what's new and update in a click.",
            category: Category.update,
            slug: nil
        )
    }

    // MARK: - Posting

    private func post(id: String, title: String, body: String, category: String, slug: String?) {
        guard Self.available else { return }
        Task {
            guard await ensureAuthorized() else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = category
            if let slug {
                content.userInfo = ["slug": slug]
            }
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private func ensureAuthorized() async -> Bool {
        if let authorized { return authorized }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let granted: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional: granted = true
        case .notDetermined: granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: granted = false
        }
        authorized = granted
        return granted
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        let slug = response.notification.request.content.userInfo["slug"] as? String
        await MainActor.run {
            handle(action: action, category: category, slug: slug)
        }
    }

    private func handle(action: String, category: String, slug: String?) {
        switch (category, action) {
        case (Category.update, Action.install):
            onInstallUpdate?()
        case (Category.update, _):
            onShowUpdate?()
        case (Category.copyBehind, Action.restart):
            if let slug, let entry = model.entries.first(where: { $0.id == slug }) {
                model.restart(entry)
            }
        default:
            if let slug {
                onShowInstance?(slug)
            }
        }
    }
}
