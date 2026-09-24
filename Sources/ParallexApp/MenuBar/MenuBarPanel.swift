import AppKit
import ParallexCore
import SwiftUI

/// The menu-bar panel: every instance one click away, the one in front
/// called out, and the ways into the rest of Parallex.
struct MenuBarPanel: View {
    let showSwitcher: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(Updater.self) private var updater
    @Environment(\.checkForUpdates) private var checkForUpdates

    var body: some View {
        VStack(spacing: 0) {
            header
            divider
            if !model.workspaces.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(model.workspaces) { workspace in
                            WorkspaceChip(workspace: workspace, members: model.members(of: workspace)) {
                                model.openWorkspace(workspace)
                                closePanel()
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, Theme.Space.s)
                }
                .scrollIndicators(.hidden)
                divider
            }
            if model.entries.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(model.entries) { entry in
                            PanelInstanceRow(entry: entry, isFront: model.frontmost?.id == entry.id) {
                                model.activate(entry)
                                closePanel()
                            } openOriginal: {
                                model.launchOriginal(entry)
                                closePanel()
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            }
            divider
            VStack(spacing: 1) {
                PanelAction(title: "New Instance…", symbol: "plus", shortcut: "⌘N") {
                    model.creating = .init()
                    showMainWindow()
                }
                PanelAction(title: "Switch To…", symbol: "arrow.left.arrow.right", shortcut: "⌃⌥Space") {
                    closePanel()
                    showSwitcher()
                }
                PanelAction(title: "Open Parallex", symbol: "macwindow", shortcut: nil) { showMainWindow() }
                SettingsLink {
                    PanelActionLabel(title: "Settings…", symbol: "gearshape", shortcut: "⌘,")
                }
                .buttonStyle(PanelRowButtonStyle())
            }
            .padding(6)
            divider
            HStack {
                if let release = updater.available {
                    Button {
                        closePanel()
                        checkForUpdates()
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(Theme.accent).frame(width: 6, height: 6)
                            Text("Update to \(release.version)")
                        }
                    }
                    .buttonStyle(.plain)
                    .font(Theme.Font.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                } else {
                    Text("Parallex \(ParallexConfigVersion.current)")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(Theme.Font.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .keyboardShortcut("q", modifiers: .command)
            }
            .padding(.horizontal, Theme.Space.m + 2)
            .padding(.vertical, Theme.Space.s)
        }
        .frame(width: 320)
        .tint(Theme.accent)
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ParallelMark(size: 20, split: 1)
            Text("Parallex").font(Theme.Font.headline)
            Spacer()
            if let front = model.frontmost {
                HStack(spacing: 5) {
                    Circle().fill(front.color).frame(width: 7, height: 7)
                    Text("In \(front.name)")
                        .font(Theme.Font.caption.weight(.medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Theme.subtleFill, in: .capsule)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Space.m + 2)
        .frame(height: 44)
        .animation(Theme.Motion.fade, value: model.frontmost?.id)
    }

    private var empty: some View {
        VStack(spacing: Theme.Space.s) {
            Text("No instances yet").font(Theme.Font.headline)
            Text("Duplicate an app to run it side by side with its own data.")
                .font(Theme.Font.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity)
    }

    private func showMainWindow() {
        closePanel()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        openWindow(id: SceneID.main)
    }

    private func closePanel() {
        NSApp.keyWindow?.close()
    }
}

/// Version string without importing ParallexKit into every view.
enum ParallexConfigVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

private struct PanelInstanceRow: View {
    let entry: InstanceEntry
    let isFront: Bool
    let open: () -> Void
    let openOriginal: () -> Void
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    /// Over the arrow: the row says what it does (menu bar panels don't
    /// show tooltips).
    @State private var hoveringOriginal = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    InstanceGlyph(iconPath: entry.iconPath, color: entry.color, size: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(entry.name)
                            .font(Theme.Font.body.weight(isFront ? .semibold : .regular))
                            .lineLimit(1)
                        Text(hoveringOriginal ? "Opens the original \(entry.targetName)"
                             : model.memoryText(entry).map { "\(entry.targetName) · \($0)" } ?? entry.targetName)
                            .font(Theme.Font.caption)
                            .foregroundStyle(hoveringOriginal ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                            .contentTransition(.opacity)
                    }
                    Spacer(minLength: 0)
                    if let shortcut = entry.manifest.settings?.shortcut, !hovering {
                        Text(shortcut.displayString)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .transition(.opacity)
                    }
                    if entry.running {
                        Circle()
                            .fill(Theme.running)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel("Running")
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!entry.status.canLaunch)

            if hovering, !entry.manifest.isWeb {
                Button(action: openOriginal) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Open the original \(entry.targetName)")
                .accessibilityLabel("Open the original \(entry.targetName)")
                .onHover { hoveringOriginal = $0 }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hovering ? Theme.subtleFill : .clear, in: .rect(cornerRadius: 7))
        .onHover { inside in
            hovering = inside
            if !inside { hoveringOriginal = false }
        }
        .animation(Theme.Motion.fade, value: hovering)
        .animation(Theme.Motion.fade, value: hoveringOriginal)
    }
}

private struct PanelAction: View {
    let title: String
    let symbol: String
    let shortcut: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PanelActionLabel(title: title, symbol: symbol, shortcut: shortcut)
        }
        .buttonStyle(PanelRowButtonStyle())
    }
}

private struct PanelActionLabel: View {
    let title: String
    let symbol: String
    let shortcut: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title).font(Theme.Font.body)
            Spacer()
            if let shortcut {
                Text(shortcut)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .contentShape(.rect)
    }
}

private struct PanelRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverHighlight(pressed: configuration.isPressed) { configuration.label }
    }
}

/// Row highlight on hover and press (hover state lives in a view, not the style).
private struct HoverHighlight<Content: View>: View {
    let pressed: Bool
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        content
            .background(
                (pressed ? Theme.accent.opacity(0.18) : hovering ? Theme.subtleFill : .clear),
                in: .rect(cornerRadius: 7)
            )
            .onHover { hovering = $0 }
    }
}

/// A workspace in the menu bar panel: one click opens all of it.
private struct WorkspaceChip: View {
    let workspace: Workspace
    let members: [InstanceEntry]
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                WorkspaceGlyph(members: members, size: 18)
                Text(workspace.name)
                    .font(Theme.Font.callout.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .frame(height: 26)
            .background(hovering ? Theme.subtleFill.opacity(1.6) : Theme.subtleFill, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(workspace.shortcut.map { "Open \(workspace.name) (\($0.displayString))" } ?? "Open \(workspace.name)")
        .disabled(members.isEmpty)
    }
}
