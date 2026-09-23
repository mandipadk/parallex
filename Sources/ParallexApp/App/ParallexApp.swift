import AppKit
import ParallexCore
import ParallexKit
import SwiftUI

enum PreferenceKey {
    static let onboardingCompleted = "onboardingCompleted"
    /// Set once onboarding has finished at least once; a re-run then starts
    /// from the current settings instead of the recommended defaults.
    static let onboardingSeen = "onboardingSeen"
    static let tagWindows = "tagInstanceWindows"
    /// Rebuild instances automatically when they only need routine upkeep.
    static let autoMaintain = "autoMaintainInstances"
    static let tagShowsName = "tagShowsName"
    static let switcherHotKey = "switcherHotKeyEnabled"
    /// Notify when an instance needs attention (on by default).
    static let notifyProblems = "notifyInstanceProblems"
    /// Notify when a Parallex update is available (on by default).
    static let notifyUpdates = "notifyUpdates"
    /// The last version whose What's New the user has seen.
    static let lastSeenVersion = "lastSeenVersion"
}

extension Notification.Name {
    /// Posted when a preference the app delegate acts on changes.
    static let parallexPreferencesChanged = Notification.Name("ParallexPreferencesChanged")
}

enum SceneID {
    static let main = "main"
}

extension EnvironmentValues {
    /// Opens the What's New window.
    @Entry var showWhatsNew: () -> Void = {}
    /// Opens Software Update and checks.
    @Entry var checkForUpdates: () -> Void = {}
}

@main
struct ParallexApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Parallex", id: SceneID.main) {
            MainWindow()
                .environment(delegate.model)
                .environment(delegate.updater)
                .capturesWindowOpener()
        }
        .defaultSize(width: 980, height: 660)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { delegate.checkForUpdates() }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Instance…") { delegate.model.creating = .init() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Switch To…") { delegate.switcher.show() }
                    .keyboardShortcut(" ", modifiers: [.control, .option])
            }
        }

        Settings {
            SettingsView()
                .environment(delegate.model)
                .environment(delegate.updater)
                .environment(\.showWhatsNew, { delegate.windows.showWhatsNew() })
                .environment(\.checkForUpdates, { delegate.checkForUpdates() })
        }

        MenuBarExtra {
            MenuBarPanel(showSwitcher: { delegate.switcher.show() })
                .environment(delegate.model)
                .environment(delegate.updater)
                .environment(\.checkForUpdates, { delegate.checkForUpdates() })
                .capturesWindowOpener()
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the long-lived services — the model, window outlines, the switcher —
/// and makes Parallex behave like a menu-bar app: a Dock icon only while its
/// window is open, and no window when it starts at login.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let updater = Updater()
    lazy var windows = AppWindows(model: model, updater: updater)
    lazy var switcher = SwitcherController(model: model)
    private lazy var shortcuts = InstanceShortcuts(model: model)
    private lazy var notifier = Notifier(model: model)
    /// What's New waits for the first time the window opens after a login launch.
    private var whatsNewPending = false
    private let tagger = WindowTagger()
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            PreferenceKey.tagWindows: true,
            PreferenceKey.tagShowsName: true,
            PreferenceKey.switcherHotKey: true,
        ])
        // People upgrading with instances already set up skip the first-run
        // flow (it stays available from Settings › Show Welcome).
        let defaults = UserDefaults.standard
        if defaults.object(forKey: PreferenceKey.onboardingCompleted) == nil, !model.entries.isEmpty {
            defaults.set(true, forKey: PreferenceKey.onboardingCompleted)
            defaults.set(true, forKey: PreferenceKey.onboardingSeen)
        }
        applyPreferences()
        trackTagTargets()
        _ = shortcuts
        setUpUpdates()
        observers.append(NotificationCenter.default.addObserver(
            forName: .parallexPreferencesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyPreferences() }
        })
        manageActivationPolicy()

        let upgraded = pendingWhatsNew()
        if launchedAsLoginItem {
            // Start in the menu bar only.
            DispatchQueue.main.async {
                NSApp.windows.filter(Self.isMainWindow).forEach { $0.close() }
                NSApp.setActivationPolicy(.accessory)
            }
            whatsNewPending = upgraded
        } else if upgraded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showWhatsNew() }
        }
        #if DEBUG
        if DebugRoute.value != nil {
            // Visual review: show windows as active, the way people see them.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        #endif
        model.maintainInstances()
        model.openAutostartInstances()
        Task { await LinkRouting.reassert() }
    }

    // MARK: - Updates and What's New

    private func setUpUpdates() {
        updater.notifier = notifier
        updater.showWindow = { [weak self] in self?.windows.showUpdate() }
        notifier.onShowInstance = { [weak self] slug in self?.windows.showMain(selecting: slug) }
        notifier.onShowUpdate = { [weak self] in self?.checkForUpdates() }
        notifier.onInstallUpdate = { [weak self] in
            guard let self else { return }
            if let release = updater.available {
                windows.showUpdate()
                updater.install(release)
            } else {
                checkForUpdates()
            }
        }
        updater.start()
    }

    func checkForUpdates() {
        windows.showUpdate()
        if updater.available == nil {
            updater.check(userInitiated: true)
        }
    }

    /// Whether this launch is the first since Parallex updated, for someone
    /// who already uses it (a fresh install gets onboarding instead).
    private func pendingWhatsNew() -> Bool {
        let defaults = UserDefaults.standard
        let current = ParallexConfig.version
        let lastSeen = defaults.string(forKey: PreferenceKey.lastSeenVersion)
        guard defaults.bool(forKey: PreferenceKey.onboardingCompleted) else { return false }
        guard lastSeen.map({ UpdateFeed.isNewer(current, than: $0) }) ?? true else { return false }
        return ReleaseHighlights.releases.contains { $0.version == current }
    }

    private func showWhatsNew() {
        UserDefaults.standard.set(ParallexConfig.version, forKey: PreferenceKey.lastSeenVersion)
        whatsNewPending = false
        windows.showWhatsNew()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon (or reopening) with no window brings the
    /// main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !flag
    }

    func applyPreferences() {
        let defaults = UserDefaults.standard
        tagger.showsNameTag = defaults.bool(forKey: PreferenceKey.tagShowsName)
        if defaults.bool(forKey: PreferenceKey.tagWindows) {
            tagger.start()
        } else {
            tagger.stop()
        }
        switcher.setHotKeyEnabled(defaults.bool(forKey: PreferenceKey.switcherHotKey))
    }

    /// Keep the outline targets in step with running instances.
    private func trackTagTargets() {
        withObservationTracking {
            tagger.setTargets(model.entries.compactMap { entry in
                entry.pid.map { WindowTagger.Target(pid: $0, name: entry.name, color: entry.nsColor) }
            })
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackTagTargets() }
        }
    }

    /// A Dock icon while the main window is open; menu bar only otherwise.
    private func manageActivationPolicy() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { notification in
            guard let window = notification.object as? NSWindow, Self.isMainWindow(window) else { return }
            Task { @MainActor [weak self] in
                if NSApp.activationPolicy() != .regular {
                    NSApp.setActivationPolicy(.regular)
                }
                if self?.whatsNewPending == true {
                    self?.showWhatsNew()
                }
            }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { notification in
            guard let window = notification.object as? NSWindow, Self.isMainWindow(window) else { return }
            Task { @MainActor in
                NSApp.setActivationPolicy(.accessory)
            }
        })
    }

    nonisolated static func isMainWindow(_ window: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            window.identifier?.rawValue.hasPrefix(SceneID.main) == true
        }
    }

    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

/// The menu bar icon; while an instance is the frontmost app it shows that
/// instance's color and name — the one place macOS itself won't.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        if let front = model.frontmost {
            Image(nsImage: Self.dot(front.nsColor))
            Text(front.name)
        } else {
            Image(nsImage: Self.mark)
        }
    }

    static func dot(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The parallel mark as a template image, drawn to the menu bar's grid.
    static let mark: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: true) { _ in
            let back = NSBezierPath(roundedRect: NSRect(x: 2, y: 1.5, width: 10, height: 10), xRadius: 2.8, yRadius: 2.8)
            back.lineWidth = 1.4
            NSColor.black.setStroke()
            back.stroke()
            let front = NSBezierPath(roundedRect: NSRect(x: 6, y: 4.5, width: 10, height: 10), xRadius: 2.8, yRadius: 2.8)
            NSColor.black.setFill()
            front.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
