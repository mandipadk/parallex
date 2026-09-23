import AppKit
import Combine
import ServiceManagement
import SwiftUI
import ParallexCore

enum PreferenceKey {
    static let tagWindows = "tagInstanceWindows"
    static let tagShowsName = "tagShowsName"
    static let switcherHotKey = "switcherHotKeyEnabled"
}

@main
struct ParallexApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Parallex", id: "manager") {
            ManagerView()
                .environmentObject(delegate.model)
                .frame(minWidth: 580, minHeight: 360)
        }
        .defaultSize(width: 700, height: 480)

        Settings {
            SettingsView(onChange: { delegate.applyPreferences() })
        }

        MenuBarExtra {
            MenuBarContent(onSwitch: { delegate.switcher.show() })
                .environmentObject(delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
    }
}

/// Owns the long-lived services: the instance model, the window tagger, and
/// the switcher.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = InstancesModel()
    lazy var switcher = SwitcherController(model: model)
    private let tagger = WindowTagger()
    private var subscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            PreferenceKey.tagWindows: true,
            PreferenceKey.tagShowsName: true,
            PreferenceKey.switcherHotKey: true,
        ])
        model.$entries
            .sink { [weak self] entries in self?.updateTagTargets(entries) }
            .store(in: &subscriptions)
        applyPreferences()
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

    private func updateTagTargets(_ entries: [InstancesModel.Entry]) {
        tagger.setTargets(entries.compactMap { entry in
            entry.pid.map { WindowTagger.Target(pid: $0, name: entry.manifest.name, color: entry.color) }
        })
    }
}

/// The menu bar icon; while an instance is the frontmost app it shows that
/// instance's color and name — the one place macOS itself won't.
struct MenuBarLabel: View {
    @ObservedObject var model: InstancesModel

    var body: some View {
        if let front = model.frontmost {
            Image(nsImage: Self.dot(front.color))
            Text(front.manifest.name)
        } else {
            Image(systemName: "square.on.square")
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
}

/// Quick-launch menu in the menu bar: every instance one click away, without
/// opening the manager window.
struct MenuBarContent: View {
    @EnvironmentObject private var model: InstancesModel
    @Environment(\.openWindow) private var openWindow
    var onSwitch: () -> Void

    var body: some View {
        if model.entries.isEmpty {
            Text("No instances yet")
        }
        ForEach(model.entries) { entry in
            Button {
                model.activate(entry)
            } label: {
                Image(nsImage: MenuBarLabel.dot(entry.color))
                Text(entry.running ? "\(entry.manifest.name) — running" : entry.manifest.name)
            }
            .disabled(!entry.status.canLaunch)
        }
        Divider()
        Button("Switch To…") { onSwitch() }
            .keyboardShortcut(" ", modifiers: [.control, .option])
        Button("Manage Instances…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "manager")
        }
        SettingsLink14()
        Divider()
        Button("Quit Parallex") {
            NSApp.terminate(nil)
        }
    }
}

/// "Settings…" that works on macOS 13 (SettingsLink is 14+).
struct SettingsLink14: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink { Text("Settings…") }
        } else {
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }
}

struct SettingsView: View {
    var onChange: () -> Void
    @AppStorage(PreferenceKey.tagWindows) private var tagWindows = true
    @AppStorage(PreferenceKey.tagShowsName) private var tagShowsName = true
    @AppStorage(PreferenceKey.switcherHotKey) private var switcherHotKey = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Outline instance windows in their color", isOn: $tagWindows)
                Toggle("Show the instance name on the outline", isOn: $tagShowsName)
                    .disabled(!tagWindows)
            } header: {
                Text("Telling instances apart")
            } footer: {
                Text("A running instance appears to macOS as the original app, so the Dock and ⌘-Tab can't distinguish them. The outline marks instance windows; the original stays unmarked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("⌃⌥Space opens the instance switcher", isOn: $switcherHotKey)
                Text("macOS also offers ⌃⌥Space for “Select next source in Input menu” (Keyboard Shortcuts › Input Sources); if that's on, it takes precedence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Open Parallex at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            loginError = error.localizedDescription
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onChange(of: tagWindows) { _ in onChange() }
        .onChange(of: tagShowsName) { _ in onChange() }
        .onChange(of: switcherHotKey) { _ in onChange() }
    }
}
