import AppKit
import SwiftUI
import ParallexCore

struct ManagerView: View {
    @EnvironmentObject private var model: InstancesModel
    @State private var showCreateSheet = false
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
                Text("This instance is currently running; it will keep running until you quit it. Removed items go to the Trash.")
            } else {
                Text("Removed items go to the Trash, not deleted outright.")
            }
        }
        .onAppear { model.refresh() }
    }

    private var instanceList: some View {
        List {
            ForEach(model.entries) { entry in
                InstanceRow(
                    entry: entry,
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
                Text("To open the original app while an instance is running, use “Launch Original” from the ⋯ menu — a plain click would just focus the instance.")
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
            Text("An instance is a second, fully independent copy of an app —\nits own Dock icon, its own data, its own logins.")
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
    var onRemove: () -> Void
    @EnvironmentObject private var model: InstancesModel

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: wrapperIcon)
                .resizable()
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.manifest.name)
                        .font(.headline)
                    if entry.running {
                        Label("Running", systemImage: "circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.green)
                            .imageScale(.small)
                    }
                }
                Text("\(entry.targetName) · \(entry.manifest.mode.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let problem = entry.problem {
                    // A pending rebuild is advice; missing pieces are errors.
                    let fatal = !entry.wrapperExists || !entry.targetExists
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(fatal ? Color.red : Color.orange)
                }
            }

            Spacer()

            Button {
                model.launch(entry)
            } label: {
                Image(systemName: "play.fill")
            }
            .help("Launch this instance")
            .disabled(!entry.wrapperExists)

            Menu {
                Button("Launch Original \(entry.targetName)") { model.launchOriginal(entry) }
                Divider()
                Button("Rebuild Wrapper") { model.rebuild(entry) }
                Button("Reveal Wrapper in Finder") { model.revealWrapper(entry) }
                Button("Show Instance Data") { model.revealData(entry) }
                Divider()
                Button("Remove…", role: .destructive) { onRemove() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 40)
        }
        .padding(.vertical, 4)
    }

    private var wrapperIcon: NSImage {
        if entry.wrapperExists {
            return NSWorkspace.shared.icon(forFile: entry.manifest.wrapperPath)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
