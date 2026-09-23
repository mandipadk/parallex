import AppKit
import Carbon.HIToolbox
import SwiftUI
import ParallexCore

/// A keyboard switcher (⌃⌥Space) that lists every instance and every running
/// original, by name. The Dock and ⌘-Tab can't tell a running instance from
/// its original — they carry the same identity — so this is the reliable way
/// to jump to the right one.
@MainActor
final class SwitcherController {
    private let model: InstancesModel
    private var panel: SwitcherPanel?
    private var keyMonitor: Any?
    private let state = SwitcherState()
    private var hotKey: GlobalHotKey?

    init(model: InstancesModel) {
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
        let size = NSSize(width: 460, height: 340)
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
        case instance(InstancesModel.Entry)
        case runningOriginal(pid: pid_t)
        case launchOriginal(InstancesModel.Entry)
    }

    let id: String
    let title: String
    let subtitle: String
    let color: NSColor?
    let icon: NSImage
    let kind: Kind

    @MainActor
    func perform(_ model: InstancesModel) {
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
    static func all(from model: InstancesModel) -> [SwitcherItem] {
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
                color: entry.color,
                icon: NSWorkspace.shared.icon(forFile: entry.manifest.wrapperPath),
                kind: .instance(entry)
            ))
        }
        // One row per original app: jump to it if it's running (a process
        // with the target's bundle ID that isn't one of our instances),
        // otherwise offer to open it alongside.
        var seenTargets = Set<String>()
        for entry in model.entries where !seenTargets.contains(entry.manifest.targetApp) {
            seenTargets.insert(entry.manifest.targetApp)
            let icon = NSWorkspace.shared.icon(forFile: entry.manifest.targetApp)
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
final class SwitcherState: ObservableObject {
    @Published var items: [SwitcherItem] = []
    @Published var query = "" {
        didSet { selection = 0 }
    }
    @Published var selection = 0

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
    @ObservedObject var state: SwitcherState
    var onChoose: (SwitcherItem) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.on.square")
                    .foregroundStyle(.secondary)
                TextField("Switch to…", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        let list = state.filtered
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == state.selection)
                                .id(item.id)
                                .onTapGesture { onChoose(item) }
                        }
                        if list.isEmpty {
                            Text("No matches")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 20)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: state.selection) { _ in
                    if let item = state.selectedItem {
                        proxy.scrollTo(item.id)
                    }
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .onAppear { searchFocused = true }
    }

    private func row(_ item: SwitcherItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if let color = item.color {
                        Circle().fill(Color(nsColor: color)).frame(width: 8, height: 8)
                    }
                    Text(item.title).font(.body.weight(.medium))
                }
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .contentShape(Rectangle())
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
