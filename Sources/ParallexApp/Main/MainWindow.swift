import ParallexCore
import SwiftUI

/// The Parallex window: onboarding on first run, then instances on the left
/// and the selected one on the right.
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PreferenceKey.onboardingCompleted) private var onboardingCompleted = false

    var body: some View {
        #if DEBUG
        if let app = DebugRoute.inlineCreate {
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
            detail
        }
        .toolbar {
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
            NewInstanceFlow(preselected: intent.app)
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
        if let entry = model.selectedEntry {
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
            ForEach(model.groups, id: \.app) { group in
                Section {
                    ForEach(group.entries) { entry in
                        SidebarRow(entry: entry, size: model.storage[entry.id]?.totalBytes)
                            .tag(entry.id)
                            .contextMenu { rowMenu(entry) }
                    }
                } header: {
                    Text(group.app)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                model.creating = .init()
            } label: {
                Label("New Instance", systemImage: "plus")
                    .font(Theme.Font.body.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
            .keyboardShortcut("n", modifiers: .command)
        }
    }

    @ViewBuilder private func rowMenu(_ entry: InstanceEntry) -> some View {
        Button(entry.running ? "Bring to Front" : "Open") { model.activate(entry) }
        Button("Open Original \(entry.targetName)") { model.launchOriginal(entry) }
        Divider()
        Button("Show in Finder") { model.reveal(entry.manifest.wrapperPath) }
        Button("Show Data Folder") { model.revealData(entry) }
    }
}

struct SidebarRow: View {
    let entry: InstanceEntry
    let size: Int64?

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
            StatusPill(state: .running)
        case .stopped:
            Text(size.map { InstanceStorage.format($0) } ?? "Not running")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case .attention, .broken:
            StatusPill(state: entry.runState)
        }
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
