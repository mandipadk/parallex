import AppKit
import Carbon.HIToolbox
import ParallexCore

/// System-wide hotkeys via the Carbon event API (no Accessibility permission
/// needed). One event handler serves every registered hotkey.
@MainActor
final class GlobalHotKey {
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32

    private static var actions: [UInt32: @MainActor () -> Void] = [:]
    private static var nextID: UInt32 = 1
    nonisolated(unsafe) private static var handlerRef: EventHandlerRef?
    /// While a shortcut is being recorded, presses are left to the recorder.
    static var suspended = false

    /// Registers the hotkey; nil if the system refused it (usually because
    /// another app already owns that key combination).
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        guard Self.installHandler() else { return nil }
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x5058_484B), id: id) // 'PXHK'
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            return nil
        }
        Self.actions[id] = action
    }

    convenience init?(_ shortcut: KeyShortcut, action: @escaping @MainActor () -> Void) {
        self.init(keyCode: UInt32(shortcut.keyCode), modifiers: Self.carbonModifiers(shortcut.modifiers), action: action)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        let id = self.id
        MainActor.assumeIsolated { _ = GlobalHotKey.actions.removeValue(forKey: id) }
    }

    static func carbonModifiers(_ modifiers: KeyShortcut.Modifiers) -> UInt32 {
        var carbon = 0
        if modifiers.contains(.control) { carbon |= controlKey }
        if modifiers.contains(.option) { carbon |= optionKey }
        if modifiers.contains(.shift) { carbon |= shiftKey }
        if modifiers.contains(.command) { carbon |= cmdKey }
        return UInt32(carbon)
    }

    private static func installHandler() -> Bool {
        if handlerRef != nil { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let read = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard read == noErr, hotKeyID.signature == OSType(0x5058_484B) else {
                return OSStatus(eventNotHandledErr)
            }
            let pressed = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !GlobalHotKey.suspended else { return }
                    GlobalHotKey.actions[pressed]?()
                }
            }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        return status == noErr
    }
}

/// Keeps one global hotkey per instance and workspace shortcut, in step with
/// the registry. An instance's shortcut opens it, brings it forward if it's
/// running, or hides it if it's already in front — one key to summon and
/// dismiss. A workspace's shortcut opens the workspace.
@MainActor
final class InstanceShortcuts {
    private let model: AppModel
    private var registered: [String: (shortcut: KeyShortcut, hotKey: GlobalHotKey)] = [:]

    init(model: AppModel) {
        self.model = model
        track()
    }

    private func track() {
        withObservationTracking {
            sync(model.entries, model.workspaces)
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
    }

    private func sync(_ entries: [InstanceEntry], _ workspaces: [Workspace]) {
        var wanted: [String: KeyShortcut] = [:]
        if !model.recordingShortcut {
            for entry in entries {
                if let shortcut = entry.manifest.settings?.shortcut, shortcut.isValidGlobal {
                    wanted[entry.id] = shortcut
                }
            }
            for workspace in workspaces {
                if let shortcut = workspace.shortcut, shortcut.isValidGlobal {
                    wanted[AppModel.tag(for: workspace)] = shortcut
                }
            }
        }
        for (slug, current) in registered where wanted[slug] != current.shortcut {
            registered[slug] = nil
        }
        var unavailable: Set<String> = []
        for (slug, shortcut) in wanted where registered[slug] == nil {
            if let hotKey = GlobalHotKey(shortcut, action: { [weak self] in self?.fire(slug) }) {
                registered[slug] = (shortcut, hotKey)
            } else {
                unavailable.insert(slug)
            }
        }
        model.setUnavailableShortcuts(unavailable)
    }

    private func fire(_ slug: String) {
        model.refresh()
        if slug.hasPrefix(AppModel.workspaceTagPrefix) {
            if let workspace = model.workspaces.first(where: { AppModel.tag(for: $0) == slug }) {
                model.openWorkspace(workspace)
            }
            return
        }
        guard let entry = model.entries.first(where: { $0.id == slug }) else { return }
        model.bringForwardOrHide(entry)
    }
}
