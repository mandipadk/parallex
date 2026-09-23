import AppKit
import Observation
import Carbon.HIToolbox
import SwiftUI
import ParallexCore

/// A keyboard switcher (⌃⌥Space) that lists every instance and every running
/// original, by name. The Dock and ⌘-Tab can't tell a running instance from
/// its original — they carry the same identity — so this is the reliable way
/// to jump to the right one.
@MainActor
final class SwitcherController {
    private let model: AppModel
    private var panel: SwitcherPanel?
    private var keyMonitor: Any?
    private let state = SwitcherState()
    private var hotKey: GlobalHotKey?

    init(model: AppModel) {
        self.model = model
    }

    func setHotKeyEnabled(_ enabled: Bool) {
        if enabled, hotKey == nil {
            hotKey = GlobalHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
                self?.toggle()
            }
        } else if !enabled {
            hotKey = nil
        }
    }

    func toggle() {
        if panel?.isVisible == true {
            close()
        } else {
            show()
        }
    }

    func show() {
        model.refresh()
        state.items = SwitcherItem.all(from: model)
        state.query = ""
        state.selection = 0

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: 520, height: 380)
        panel.setFrame(NSRect(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.midY + 40,
            width: size.width,
            height: size.height
        ), display: true)
        panel.makeKeyAndOrderFront(nil)

        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isKeyWindow == true else { return event }
            switch Int(event.keyCode) {
            case kVK_Escape:
                self.close()
                return nil
            case kVK_DownArrow:
                self.state.move(by: 1)
                return nil
            case kVK_UpArrow:
                self.state.move(by: -1)
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                self.choose(self.state.selectedItem)
                return nil
            default:
                return event
            }
        }
    }

    func close() {
        panel?.orderOut(nil)
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private func choose(_ item: SwitcherItem?) {
        close()
        item?.perform(model)
    }

    private func makePanel() -> SwitcherPanel {
        let panel = SwitcherPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.onResignKey = { [weak self] in self?.close() }
        panel.contentView = NSHostingView(rootView: SwitcherView(
            state: state,
            onChoose: { [weak self] item in self?.choose(item) }
        ))
        return panel
    }
}

final class SwitcherPanel: NSPanel {
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// One row: an instance, or an original app.
struct SwitcherItem: Identifiable {
    enum Kind {
        case instance(InstanceEntry)
        case runningOriginal(pid: pid_t)
        case launchOriginal(InstanceEntry)
    }

    let id: String
    let title: String
    let subtitle: String
    let color: NSColor?
    let icon: NSImage
    let kind: Kind

    @MainActor
    func perform(_ model: AppModel) {
        switch kind {
        case .instance(let entry):
            model.activate(entry)
        case .runningOriginal(let pid):
            InstanceLauncher.activate(pid: pid)
        case .launchOriginal(let entry):
            model.launchOriginal(entry)
        }
    }

    @MainActor
    static func all(from model: AppModel) -> [SwitcherItem] {
        var items: [SwitcherItem] = []
        let instancePIDs = Set(model.entries.compactMap(\.pid))
        let entries = model.entries.sorted { lhs, rhs in
            lhs.running != rhs.running ? lhs.running : lhs.manifest.name < rhs.manifest.name
        }
        for entry in entries where entry.status.canLaunch {
            items.append(SwitcherItem(
                id: "instance-\(entry.id)",
                title: entry.manifest.name,
                subtitle: entry.running ? "\(entry.targetName) instance · running" : "\(entry.targetName) instance",
                color: entry.nsColor,
                icon: IconCache.icon(for: entry.iconPath),
                kind: .instance(entry)
            ))
        }
        // One row per original app: jump to it if it's running (a process
        // with the target's bundle ID that isn't one of our instances),
        // otherwise offer to open it alongside.
        var seenTargets = Set<String>()
        for entry in model.entries where !seenTargets.contains(entry.manifest.targetApp) {
            seenTargets.insert(entry.manifest.targetApp)
            let icon = IconCache.icon(for: entry.manifest.targetApp)
            let running = entry.manifest.targetBundleID.map {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0)
            } ?? NSWorkspace.shared.runningApplications.filter {
                $0.bundleURL?.path == entry.manifest.targetApp
            }
            if let original = running.first(where: { !instancePIDs.contains($0.processIdentifier) }) {
                items.append(SwitcherItem(
                    id: "original-\(entry.manifest.targetApp)",
                    title: entry.targetName,
                    subtitle: "original · running",
                    color: nil,
                    icon: icon,
                    kind: .runningOriginal(pid: original.processIdentifier)
                ))
            } else if FileManager.default.fileExists(atPath: entry.manifest.targetApp) {
                items.append(SwitcherItem(
                    id: "open-original-\(entry.manifest.targetApp)",
                    title: entry.targetName,
                    subtitle: "original · open alongside instances",
                    color: nil,
                    icon: icon,
                    kind: .launchOriginal(entry)
                ))
            }
        }
        return items
    }
}

@MainActor
@Observable
final class SwitcherState {
    var items: [SwitcherItem] = []
    var query = "" {
        didSet { selection = 0 }
    }
    var selection = 0

    var filtered: [SwitcherItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed) || $0.subtitle.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var selectedItem: SwitcherItem? {
        let list = filtered
        return list.indices.contains(selection) ? list[selection] : nil
    }

    func move(by delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }
}

struct SwitcherView: View {
    @Bindable var state: SwitcherState
    var onChoose: (SwitcherItem) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ParallelMark(size: 18, split: 1)
                TextField("Switch to…", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($searchFocused)
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(height: 50)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        let list = state.filtered
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                            Button {
                                onChoose(item)
                            } label: {
                                row(item, selected: index == state.selection)
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                        }
                        if list.isEmpty {
                            Text("No matches")
                                .font(Theme.Font.callout)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 24)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: state.selection) {
                    if let item = state.selectedItem {
                        proxy.scrollTo(item.id)
                    }
                }
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: Theme.Space.l) {
                hint("↩", "Switch")
                hint("↑↓", "Move")
                hint("esc", "Close")
                Spacer()
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(height: 30)
        }
        .background(.regularMaterial, in: .rect(cornerRadius: Theme.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Theme.hairline))
        .onAppear { searchFocused = true }
        .tint(Theme.accent)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(Theme.subtleFill, in: .rect(cornerRadius: 4))
            Text(label).font(Theme.Font.caption)
        }
        .foregroundStyle(.secondary)
    }

    private func row(_ item: SwitcherItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 28, height: 28)
                .overlay(alignment: .bottomTrailing) {
                    if let color = item.color {
                        Circle()
                            .fill(Color(nsColor: color))
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                            .offset(x: 2, y: 2)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(Theme.Font.body.weight(.medium))
                    .foregroundStyle(selected ? .white : .primary)
                Text(item.subtitle)
                    .font(Theme.Font.caption)
                    .foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.accent : .clear)
        )
        .contentShape(.rect)
    }
}

/// A system-wide hotkey via the Carbon event API (no Accessibility
/// permission needed).
@MainActor
final class GlobalHotKey {
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?
    private let action: @MainActor () -> Void

    private static var actions: [UInt32: @MainActor () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        self.action = action
        id = Self.nextID
        Self.nextID += 1

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            let pressed = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    GlobalHotKey.actions[pressed]?()
                }
            }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        guard status == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x5058_484B), id: id) // 'PXHK'
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil
            return nil
        }
        Self.actions[id] = action
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        let id = self.id
        MainActor.assumeIsolated { _ = GlobalHotKey.actions.removeValue(forKey: id) }
    }
}
