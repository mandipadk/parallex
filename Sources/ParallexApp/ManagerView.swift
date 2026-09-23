import AppKit
import SwiftUI
import ParallexCore
import UniformTypeIdentifiers

struct ManagerView: View {
    @EnvironmentObject private var model: InstancesModel
    @State private var showCreateSheet = false
    @State private var editing: InstancesModel.Entry?
    @State private var checking: InstancesModel.Entry?
    @State private var removalCandidate: InstancesModel.Entry?

    var body: some View {
        Group {
            if model.entries.isEmpty {
                emptyState
            } else {
                instanceList
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreateSheet = true
                } label: {
                    Label("New Instance", systemImage: "plus")
                }
                .help("Create a new isolated instance of an app")
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateSheet()
                .environmentObject(model)
        }
        .sheet(item: $editing) { entry in
            EditSheet(entry: entry)
                .environmentObject(model)
        }
        .sheet(item: $checking) { entry in
            IsolationSheet(entry: entry)
                .environmentObject(model)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(model.errorMessage ?? "") }
        )
        .confirmationDialog(
            "Remove “\(removalCandidate?.manifest.name ?? "")”?",
            isPresented: Binding(
                get: { removalCandidate != nil },
                set: { if !$0 { removalCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move Wrapper and Data to Trash", role: .destructive) {
                if let entry = removalCandidate {
                    model.remove(entry, keepData: false)
                }
            }
            Button("Remove but Keep Data") {
                if let entry = removalCandidate {
                    model.remove(entry, keepData: true)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if removalCandidate?.running == true {
                Text("This instance is running — quit it first, or it will keep writing to data that's in the Trash.")
            } else {
                Text("Removed items go to the Trash, not deleted outright.")
            }
        }
        .onAppear {
            model.refresh()
            model.measureStorage()
        }
    }

    private var instanceList: some View {
        List {
            ForEach(model.entries) { entry in
                InstanceRow(
                    entry: entry,
                    onEdit: { editing = entry },
                    onCheck: { checking = entry },
                    onRemove: { removalCandidate = entry }
                )
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                Text("A running instance shows up in the Dock as the original app. The menu bar and window tags show which one you're in; use “Launch Original” to open the original alongside.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.on.square")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("No instances yet")
                .font(.title3.weight(.semibold))
            Text("An instance is a second, independent copy of an app —\nits own data, its own logins.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showCreateSheet = true
            } label: {
                Label("Create Your First Instance", systemImage: "plus")
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct InstanceRow: View {
    let entry: InstancesModel.Entry
    var onEdit: () -> Void
    var onCheck: () -> Void
    var onRemove: () -> Void
    @EnvironmentObject private var model: InstancesModel

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: wrapperIcon)
                .resizable()
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(nsColor: entry.color))
                        .frame(width: 8, height: 8)
                    Text(entry.manifest.name)
                        .font(.headline)
                    if entry.running {
                        Text("Running")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.green)
                    }
                }
                Text(([entry.targetName, isolationSummary] + sizeLabel).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(entry.status.problems.enumerated()), id: \.offset) { _, problem in
                    Text(problem.summary)
                        .font(.caption)
                        .foregroundStyle(problem.isBlocking ? Color.red : Color.orange)
                }
            }

            Spacer()

            if model.busy.contains(entry.id) {
                ProgressView()
                    .controlSize(.small)
            } else if entry.needsRepair {
                Button("Repair") { model.repair(entry) }
                    .help("Rebuild the wrapper from this instance's saved settings")
            } else if entry.status.problems.contains(.targetMissing) {
                Button("Locate App…") { locateTarget() }
                    .help("Choose where the original app is now")
            }

            Button {
                model.activate(entry)
            } label: {
                Image(systemName: entry.running ? "arrow.up.forward.app" : "play.fill")
            }
            .help(entry.running ? "Bring this instance to the front" : "Launch this instance")
            .disabled(!entry.status.canLaunch)

            Menu {
                Button("Edit…") { onEdit() }
                Button("Check Isolation…") { onCheck() }
                    .disabled(!entry.running)
                Button("Launch Original \(entry.targetName)") { model.launchOriginal(entry) }
                Divider()
                Button("Repair Wrapper") { model.repair(entry) }
                Button("Locate Original App…") { locateTarget() }
                Button("Reveal Wrapper in Finder") { model.revealWrapper(entry) }
                Button("Show Instance Data") { model.revealData(entry) }
                if let report = model.storage[entry.id] {
                    Divider()
                    Button("Move Caches to Trash (\(InstanceStorage.format(report.cacheBytes)))") {
                        model.reclaim(.caches, of: entry)
                    }
                    .disabled(entry.running || report.caches.isEmpty)
                    Button("Move Unused Items to Trash (\(InstanceStorage.format(report.unusedBytes)))") {
                        model.reclaim(.unused, of: entry)
                    }
                    .disabled(entry.running || report.unused.isEmpty)
                }
                Divider()
                Button("Remove…", role: .destructive) { onRemove() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 40)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Edit…") { onEdit() }
            Button("Launch Original \(entry.targetName)") { model.launchOriginal(entry) }
        }
    }

    private var sizeLabel: [String] {
        model.storage[entry.id].map { [InstanceStorage.format($0.totalBytes)] } ?? []
    }

    private var isolationSummary: String {
        let manifest = entry.manifest
        if let recipe = manifest.recipe, manifest.preset == recipe.id {
            let active = manifest.effectiveSettings.activeOptions(of: recipe.options)
            let extras = recipe.options.filter { active.contains($0.id) }.map(\.title)
            return (["app recipe"] + extras).joined(separator: " · ")
        }
        return manifest.mode.rawValue
    }

    private var wrapperIcon: NSImage {
        if entry.wrapperExists {
            return NSWorkspace.shared.icon(forFile: entry.manifest.wrapperPath)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }

    private func locateTarget() {
        let panel = NSOpenPanel()
        panel.title = "Where is \(entry.targetName) now?"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        model.repair(entry, targetApp: url)
    }
}
