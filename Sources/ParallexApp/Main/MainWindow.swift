import ParallexCore
import SwiftUI

/// The Parallex window: onboarding on first run, then instances on the left
/// and the selected one on the right.
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PreferenceKey.onboardingCompleted) private var onboardingCompleted = false
    #if DEBUG
    @Environment(Updater.self) private var updater
    #endif

    var body: some View {
        #if DEBUG
        if DebugRoute.showsWhatsNew {
            WhatsNewView {}
        } else if let phase = DebugRoute.updatePhase {
            UpdateView {}.onAppear { updater.debugShow(phase) }
        } else if DebugRoute.value == "newWorkspace" {
            NewWorkspaceSheet()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let address = DebugRoute.webCreate {
            NewInstanceFlow(webAddress: address)
        } else if let app = DebugRoute.inlineCreate {
            NewInstanceFlow(preselected: app.isEmpty ? nil : URL(fileURLWithPath: app))
        } else if DebugRoute.showsSettings {
            SettingsView()
        } else if DebugRoute.showsMenuPanel {
            MenuBarPanel(showSwitcher: {}).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            content
        }
        #else
        content
        #endif
    }

    private var content: some View {
        Group {
            if onboardingCompleted {
                InstancesView()
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.smooth, value: onboardingCompleted)
        .tint(Theme.accent)
    }
}

struct InstancesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            // The same frosted material as the sidebar, so the window reads
            // as one surface rather than three shades of gray.
            // Clipped below the toolbar: with no toolbar band, content scrolling
            // up would otherwise run under the title and the + button.
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .background(WindowGlassBackground(material: .sidebar).ignoresSafeArea())
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            // The window's title: a quiet wordmark rather than empty space.
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 7) {
                    ParallelMark(size: 17, split: 1)
                    Text("Parallex")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Parallex")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.creating = .init()
                } label: {
                    Label("New Instance", systemImage: "plus")
                }
                .help("New Instance (⌘N)")
            }
        }
        .sheet(item: $model.creating) { intent in
            NewInstanceFlow(preselected: intent.app, webAddress: intent.website)
        }
        .sheet(isPresented: $model.makingWorkspace) {
            NewWorkspaceSheet()
        }
        .alert(item: $model.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                primaryButton: .default(Text("Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting(notice.reveal)
                },
                secondaryButton: .cancel(Text("Later"))
            )
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(model.errorMessage ?? "") }
        )
        .onAppear {
            if model.selection == nil {
                model.selection = model.entries.first?.id
            }
            model.measureStorage()
            #if DEBUG
            if let slug = DebugRoute.selectedInstance { model.selection = slug }
            if let app = DebugRoute.createApp {
                model.creating = .init(app: app.isEmpty ? nil : URL(fileURLWithPath: app))
            }
            #endif
        }
    }

    @ViewBuilder private var detail: some View {
        if let workspace = model.selectedWorkspace {
            WorkspaceDetail(workspace: workspace)
                .id(workspace.id)
        } else if let entry = model.selectedEntry {
            InstanceDetail(entry: entry)
                .id(entry.id)
        } else if model.entries.isEmpty {
            EmptyInstancesView()
        } else {
            Text("Select an instance")
                .font(Theme.Font.body)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            if !model.workspaces.isEmpty {
                Section("Workspaces") {
                    ForEach(model.workspaces) { workspace in
                        WorkspaceRow(workspace: workspace, members: model.members(of: workspace))
                            .tag(AppModel.tag(for: workspace))
                            .contextMenu {
                                Button("Open All") { model.openWorkspace(workspace) }
                                Button("Quit All") { model.quitWorkspace(workspace) }
                                Divider()
                                Button("Delete Workspace", role: .destructive) { model.deleteWorkspace(workspace) }
                            }
                    }
                }
            }
            ForEach(model.groups, id: \.app) { group in
                Section {
                    ForEach(group.entries) { entry in
                        SidebarRow(entry: entry, size: model.storage[entry.id]?.totalBytes, memory: model.memoryText(entry))
                            .tag(entry.id)
                            .contextMenu { rowMenu(entry) }
                    }
                } header: {
                    Text(group.app)
                }
            }
        }
        .listStyle(.sidebar)
        .bottomBar {
            VStack(spacing: 0) {
            // A message from Parallex, else (once) the support card.
            MessageCard()
                .padding(.top, Theme.Space.m)
            HStack(spacing: Theme.Space.s) {
                Button {
                    model.creating = .init()
                } label: {
                    Label("New Instance", systemImage: "plus")
                        .font(Theme.Font.body.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: .command)
                Button {
                    model.makingWorkspace = true
                } label: {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("New Workspace (⇧⌘N)")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
            }
        }
    }

    @ViewBuilder private func rowMenu(_ entry: InstanceEntry) -> some View {
        Button(entry.running ? "Bring to Front" : "Open") { model.activate(entry) }
        if !entry.manifest.isWeb {
            Button("Open Original \(entry.targetName)") { model.launchOriginal(entry) }
        }
        if !model.workspaces.isEmpty {
            Menu("Add to Workspace") {
                ForEach(model.workspaces) { workspace in
                    Button(workspace.name) {
                        model.changeWorkspace(workspace.id) { $0.members.append(entry.id) }
                    }
                    .disabled(workspace.members.contains(entry.id))
                }
            }
        }
        Divider()
        Button("Show in Finder") { model.reveal(entry.manifest.wrapperPath) }
        Button("Show Data Folder") { model.revealData(entry) }
    }
}

struct SidebarRow: View {
    let entry: InstanceEntry
    let size: Int64?
    var memory: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            InstanceGlyph(iconPath: entry.iconPath, color: entry.color, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(Theme.Font.body.weight(.medium))
                    .lineLimit(1)
                subtitle
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var subtitle: some View {
        switch entry.runState {
        case .running:
            StatusPill(state: .running, detail: memory)
        case .stopped:
            Text(stoppedDetail)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case .attention, .broken:
            StatusPill(state: entry.runState)
        }
    }

    /// Its data size — or, for an instance whose data folder is still all
    /// but empty, that it hasn't been opened yet.
    private var stoppedDetail: String {
        guard let size else { return "Not running" }
        if size < 64 * 1024 {
            return "Not opened yet"
        }
        let shortcut = entry.manifest.settings?.shortcut.map { " · \($0.displayString)" } ?? ""
        return InstanceStorage.format(size) + shortcut
    }
}

// MARK: - Empty state

struct EmptyInstancesView: View {
    @Environment(AppModel.self) private var model
    @State private var split: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            ParallelMark(size: 88, split: split)
            VStack(spacing: Theme.Space.s) {
                Text("No instances yet")
                    .font(Theme.Font.title)
                Text("An instance is a second copy of an app with its own sign-in and data.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            Button("New Instance") { model.creating = .init() }
                .buttonStyle(.primaryLarge)
                .padding(.top, Theme.Space.s)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(reduceMotion ? nil : Theme.Motion.smooth.delay(0.15)) { split = 1 }
        }
    }
}
