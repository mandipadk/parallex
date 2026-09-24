import AppKit
import ParallexCore

/// An icon in the menu bar for each instance that asks for one: a click
/// opens it, brings it forward, or hides it (like its shortcut); the menu
/// has the rest.
@MainActor
final class InstanceMenuBarIcons: NSObject {
    private let model: AppModel
    private let showInstance: (String) -> Void
    private var items: [String: (item: NSStatusItem, iconPath: String)] = [:]

    init(model: AppModel, showInstance: @escaping (String) -> Void) {
        self.model = model
        self.showInstance = showInstance
        super.init()
        track()
    }

    private func track() {
        withObservationTracking {
            sync(model.entries)
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
    }

    private func sync(_ entries: [InstanceEntry]) {
        let wanted = Dictionary(
            entries.filter { $0.manifest.settings?.menuBarIcon == true }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for (slug, current) in items where wanted[slug] == nil {
            NSStatusBar.system.removeStatusItem(current.item)
            items[slug] = nil
        }
        for (slug, entry) in wanted {
            if let current = items[slug] {
                if current.iconPath != entry.iconPath {
                    current.item.button?.image = icon(for: entry)
                    items[slug] = (current.item, entry.iconPath)
                }
                current.item.button?.toolTip = entry.name
                continue
            }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = icon(for: entry)
            item.button?.toolTip = entry.name
            item.button?.setAccessibilityLabel(entry.name)
            item.button?.identifier = NSUserInterfaceItemIdentifier(slug)
            item.button?.target = self
            item.button?.action = #selector(clicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            items[slug] = (item, entry.iconPath)
        }
    }

    private func icon(for entry: InstanceEntry) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: entry.iconPath)
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let slug = sender.identifier?.rawValue else { return }
        model.refresh()
        guard let entry = model.entries.first(where: { $0.id == slug }) else { return }
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showMenu(for: entry, from: sender)
        } else {
            model.bringForwardOrHide(entry)
        }
    }

    private func showMenu(for entry: InstanceEntry, from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: entry.running ? "Bring Forward" : "Open", action: #selector(open(_:)), keyEquivalent: "")
        if entry.running {
            menu.addItem(withTitle: "Quit \(entry.name)", action: #selector(quit(_:)), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show in Parallex", action: #selector(reveal(_:)), keyEquivalent: "")
        for item in menu.items {
            item.target = self
            item.representedObject = entry.id
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func entry(for item: NSMenuItem) -> InstanceEntry? {
        model.entries.first { $0.id == item.representedObject as? String }
    }

    @objc private func open(_ item: NSMenuItem) {
        if let entry = entry(for: item) { model.activate(entry) }
    }

    @objc private func quit(_ item: NSMenuItem) {
        if let entry = entry(for: item), let pid = entry.pid {
            NSRunningApplication(processIdentifier: pid)?.terminate()
        }
    }

    @objc private func reveal(_ item: NSMenuItem) {
        guard let entry = entry(for: item) else { return }
        showInstance(entry.id)
    }
}
