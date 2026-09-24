import ParallexCore
import SwiftUI

/// A workspace's members as a small fan of their icons (or a quiet
/// placeholder when it's empty).
struct WorkspaceGlyph: View {
    let members: [InstanceEntry]
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            if members.isEmpty {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2.5]))
                    .frame(width: size * 0.82, height: size * 0.82)
            }
            // A small fanned hand: the first instance in front, the next ones
            // tilted out behind it, all centered as a group.
            let shown = Array(members.prefix(3))
            let spread = CGFloat(shown.count - 1)
            ForEach(Array(shown.enumerated().reversed()), id: \.element.id) { index, entry in
                let position = CGFloat(index) - spread / 2
                AppIcon(path: entry.iconPath, size: size * (shown.count == 1 ? 0.92 : 0.7))
                    .shadow(color: .black.opacity(0.22), radius: size * 0.05, y: size * 0.02)
                    .rotationEffect(.degrees(Double(position) * 9), anchor: .bottom)
                    .offset(x: position * size * 0.2, y: abs(position) * size * 0.04)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct WorkspaceRow: View {
    let workspace: Workspace
    let members: [InstanceEntry]

    var body: some View {
        HStack(spacing: 10) {
            WorkspaceGlyph(members: members, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.name)
                    .font(Theme.Font.body.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let running = members.filter(\.running).count
        var parts = [members.count == 1 ? "1 instance" : "\(members.count) instances"]
        if running > 0 {
            parts.append("\(running) open")
        }
        if let shortcut = workspace.shortcut {
            parts.append(shortcut.displayString)
        }
        return parts.joined(separator: " · ")
    }
}

/// Everything about one workspace, edited in place (every change saves).
struct WorkspaceDetail: View {
    let workspace: Workspace
    @Environment(AppModel.self) private var model
    @State private var name: String
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var linkChoices = WebLinkChoices()
    @FocusState private var nameFocused: Bool

    init(workspace: Workspace) {
        self.workspace = workspace
        _name = State(initialValue: workspace.name)
    }

    private var members: [InstanceEntry] { model.members(of: workspace) }
    private var candidates: [InstanceEntry] {
        model.entries.filter { !workspace.members.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.bottom, Theme.Space.xl)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Font.callout)
                        .foregroundStyle(Theme.attention)
                        .padding(.bottom, Theme.Space.m)
                }
                membersSection
                openingSection
                footer
            }
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.top, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xxxl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("")
        .onChange(of: workspace.name) { _, fresh in name = fresh }
        .confirmationDialog("Delete “\(workspace.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Workspace", role: .destructive) { model.deleteWorkspace(workspace) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its instances aren't changed.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            WorkspaceGlyph(members: members, size: 64)
            VStack(alignment: .leading, spacing: 6) {
                // Saved when you're done (Return or leaving the field), not
                // per keystroke — links and scripts use the name.
                TextField("Workspace name", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.display)
                    .focused($nameFocused)
                    .onSubmit(rename)
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { rename() }
                    }
                Text(summary)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Space.l)
            Button("Open All") { model.openWorkspace(workspace) }
                .buttonStyle(.primary)
                .disabled(members.isEmpty)
                .keyboardShortcut("o", modifiers: .command)
            Menu {
                Button("Quit All") { model.quitWorkspace(workspace) }
                    .disabled(!members.contains(where: \.running))
                Divider()
                Button("Delete Workspace…", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(.secondary)
            .fixedSize()
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.55), in: .rect(cornerRadius: Theme.Radius.control))
            .accessibilityLabel("More actions")
        }
    }

    private var summary: String {
        let running = members.filter(\.running).count
        if members.isEmpty { return "Add the instances you use together." }
        return running == 0 ? "\(members.count) instances, none open" : "\(running) of \(members.count) open"
    }

    private var membersSection: some View {
        DetailSection(title: "Instances", subtitle: "They open in this order.") {
            VStack(spacing: 2) {
                ForEach(Array(members.enumerated()), id: \.element.id) { index, entry in
                    MemberRow(
                        entry: entry,
                        canMoveUp: index > 0,
                        canMoveDown: index < members.count - 1,
                        move: { offset in move(entry.id, by: offset) },
                        remove: { update { $0.members.removeAll { $0 == entry.id } } }
                    )
                }
                Menu {
                    ForEach(candidates) { entry in
                        Button(entry.name) { update { $0.members.append(entry.id) } }
                    }
                } label: {
                    Label("Add Instance", systemImage: "plus")
                        .font(Theme.Font.body.weight(.medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(candidates.isEmpty)
                .padding(.top, members.isEmpty ? 0 : Theme.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var openingSection: some View {
        DetailSection(title: "Opening") {
            HStack(alignment: .center, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keyboard shortcut").font(Theme.Font.body)
                    Text(shortcutUnavailable
                         ? "Another app already uses this shortcut. Record a different one."
                         : "Opens every instance in \(workspace.name) from anywhere.")
                        .font(Theme.Font.callout)
                        .foregroundStyle(shortcutUnavailable ? Theme.attention : .secondary)
                }
                Spacer(minLength: Theme.Space.l)
                ShortcutRecorder(shortcut: Binding(
                    get: { workspace.shortcut },
                    set: { shortcut in update { $0.shortcut = shortcut } }
                )) { candidate in
                    model.shortcutConflict(candidate, for: workspace.id.uuidString)
                }
            }
            ExplainedToggle(
                title: "Hide other instances",
                detail: "When it opens, instances outside \(workspace.name) step out of the way.",
                isOn: Binding(get: { workspace.hidesOthers }, set: { hides in update { $0.hidesOthers = hides } })
            )
            HStack(alignment: .center, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Web links open in").font(Theme.Font.body)
                    Text(LinkRouting.loadConfiguration().routesWeb
                         ? "Links you click in \(workspace.name)'s instances go here."
                         : "Turn on web links in Settings › Links to send links from \(workspace.name)'s instances here.")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.l)
                WebLinkTargetPicker(
                    target: Binding(get: { workspace.webLinks }, set: { target in update { $0.webLinks = target } }),
                    choices: linkChoices
                )
            }
            .onAppear { linkChoices = .load(entries: model.entries) }
        }
    }

    private var footer: some View {
        HStack {
            Text("Also opens with parallex workspace open \"\(workspace.name)\" or \(ParallexLink.url(openingWorkspace: workspace.name).absoluteString)")
                .font(Theme.Font.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding(.top, Theme.Space.xl)
    }

    private var shortcutUnavailable: Bool {
        workspace.shortcut != nil && model.unavailableShortcuts.contains(AppModel.tag(for: workspace))
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != workspace.name else { return }
        guard !trimmed.isEmpty else {
            name = workspace.name
            return
        }
        update { $0.name = trimmed }
        if error != nil {
            name = workspace.name
        }
    }

    /// Reorder among the instances shown (members that no longer exist are
    /// dropped on the way).
    private func move(_ slug: String, by offset: Int) {
        var order = members.map(\.id)
        guard let index = order.firstIndex(of: slug), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        update { $0.members = order }
    }

    private func update(_ change: (inout Workspace) -> Void) {
        withAnimation(Theme.Motion.snappy) {
            error = model.changeWorkspace(workspace.id, change)
        }
    }
}

private struct MemberRow: View {
    let entry: InstanceEntry
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            InstanceGlyph(iconPath: entry.iconPath, color: entry.color, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.name).font(Theme.Font.body.weight(.medium))
                Text(entry.targetName).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if entry.running {
                StatusPill(state: .running)
            }
            HStack(spacing: 2) {
                iconButton("chevron.up", help: "Open earlier", enabled: canMoveUp) { move(-1) }
                iconButton("chevron.down", help: "Open later", enabled: canMoveDown) { move(1) }
                iconButton("minus.circle", help: "Take out of the workspace", enabled: true, action: remove)
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hovering ? Theme.subtleFill : .clear, in: .rect(cornerRadius: 7))
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fade, value: hovering)
    }

    private func iconButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}
