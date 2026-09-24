import ParallexCore
import SwiftUI

/// A workspace in one go: a name and a color, the instances you already
/// have, and new copies of apps, made the way the catalog recommends.
struct NewWorkspaceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var colorHex = IconBuilder.palette[0]
    @State private var existing: Set<String> = []
    @State private var newApps: Set<String> = []
    @State private var making: (app: String, index: Int)?
    @State private var failures: [String] = []
    /// Made, with some apps failing: the sheet shows which, then closes.
    @State private var finished = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text("New workspace").font(Theme.Font.title)
                TextField("Name", text: $name, prompt: Text("Work, Personal, a client…"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.body)
                    .focused($nameFocused)
                ColorSwatchPicker(selection: $colorHex, palette: IconBuilder.palette)
            }
            .padding([.horizontal, .top], Theme.Space.xl)
            .padding(.bottom, Theme.Space.m)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if finished {
                        PickSection(title: "Couldn't make") {
                            ForEach(failures, id: \.self) { failure in
                                Label(failure, systemImage: "exclamationmark.triangle.fill")
                                    .font(Theme.Font.callout)
                                    .foregroundStyle(Theme.attention)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if !model.entries.isEmpty, !finished {
                        PickSection(title: "Instances you have") {
                            ForEach(model.entries) { entry in
                                PickRow(
                                    icon: entry.iconPath, title: entry.name, detail: entry.targetName,
                                    isOn: binding(for: entry.id, in: $existing)
                                )
                            }
                        }
                    }
                    if !finished {
                    PickSection(title: "New copies of") {
                        if model.catalogState != .loaded {
                            HStack(spacing: Theme.Space.s) {
                                ProgressView().controlSize(.small)
                                Text("Looking through your apps…").font(Theme.Font.callout).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, Theme.Space.s)
                        } else {
                            ForEach(apps) { app in
                                PickRow(
                                    icon: app.url.path, title: app.name, detail: app.summary,
                                    isOn: binding(for: app.id, in: $newApps)
                                )
                            }
                        }
                    }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.bottom, Theme.Space.l)
            }
            .frame(maxHeight: .infinity)

            footer
        }
        .frame(width: 520, height: 600)
        .onAppear {
            model.loadCatalog()
            name = suggestedName
            colorHex = IconBuilder.palette.first { hex in
                !model.workspaces.contains { $0.colorHex?.caseInsensitiveCompare(hex) == .orderedSame }
            } ?? IconBuilder.palette[0]
            nameFocused = true
        }
        .interactiveDismissDisabled(making != nil)
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.m) {
            if let making {
                ProgressView().controlSize(.small)
                Text("Making \(making.app)… \(making.index + 1) of \(newApps.count)")
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
            } else if !finished, let failure = failures.first {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Font.callout)
                    .foregroundStyle(Theme.attention)
                    .lineLimit(2)
            } else if finished {
                Text("“\(trimmedName)” is ready with the rest.")
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(summary).font(Theme.Font.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if finished {
                Button("Done") { dismiss() }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .disabled(making != nil)
                Button("Create", action: create)
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate || making != nil)
            }
        }
        .padding(Theme.Space.l)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    /// Apps worth a copy, best fits first (Apple's own can't be copied).
    private var apps: [CatalogApp] {
        model.catalog.filter { $0.fit != .unsupported && $0.fit != .systemParts }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var nameTaken: Bool {
        model.workspaces.contains { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }
    }

    private var canCreate: Bool { !trimmedName.isEmpty && !nameTaken }

    private var summary: String {
        if nameTaken { return "There's already a workspace called “\(trimmedName)”." }
        let count = existing.count + newApps.count
        switch count {
        case 0: return "Start empty, or pick what it holds."
        case 1: return "1 instance"
        default: return "\(count) instances"
        }
    }

    private var suggestedName: String {
        let taken = Set(model.workspaces.map { $0.name.lowercased() })
        return ["Work", "Personal", "Side Project"].first { !taken.contains($0.lowercased()) } ?? ""
    }

    private func binding(for id: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(id) },
            set: { on in
                if on { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) }
            }
        )
    }

    private func create() {
        let chosenApps = apps.filter { newApps.contains($0.id) }
        let chosenExisting = model.entries.map(\.id).filter(existing.contains)
        failures = []
        making = chosenApps.isEmpty ? nil : (chosenApps[0].name, 0)
        Task {
            let result = await model.makeWorkspace(
                name: trimmedName, colorHex: colorHex, existing: chosenExisting, newApps: chosenApps
            ) { app, index in
                making = (app, index)
            }
            making = nil
            failures = result.failures
            if result.workspace != nil, failures.isEmpty {
                dismiss()
            } else if result.workspace != nil {
                finished = true
            }
        }
    }
}

private struct PickSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            content
        }
    }
}

private struct PickRow: View {
    let icon: String
    let title: String
    let detail: String
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                AppIcon(path: icon, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.Font.body)
                    Text(detail)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 5)
            .background(hovering ? Theme.subtleFill : .clear, in: .rect(cornerRadius: Theme.Radius.tile))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isOn ? [.isToggle, .isSelected] : .isToggle)
        .animation(Theme.Motion.fade, value: hovering)
    }
}
