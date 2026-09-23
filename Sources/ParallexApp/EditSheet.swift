import AppKit
import SwiftUI
import ParallexCore
import UniformTypeIdentifiers

/// Change an existing instance. The instance keeps its slug — and with it its
/// bundle ID, data, and permissions — whatever is edited here.
struct EditSheet: View {
    let entry: InstancesModel.Entry
    @EnvironmentObject private var model: InstancesModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var badge = ""
    @State private var useCustomBadgeColor = false
    @State private var badgeColor = Color.indigo
    @State private var mode: RequestedMode = .auto
    @State private var activeOptions: Set<String> = []
    @State private var environmentText = ""
    @State private var argumentsText = ""
    @State private var newIcon: URL?
    @State private var resetIcon = false
    @State private var cloneApp = false
    @State private var cloneAssessment: AppCloner.Assessment?

    @State private var working = false
    @State private var errorMessage: String?

    private var recipeOptions: [RecipeOption] { entry.manifest.recipe?.options ?? [] }
    private var settings: InstanceSettings { entry.manifest.effectiveSettings }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Instance") {
                    TextField("Name", text: $name)
                    HStack {
                        TextField("Icon badge", text: $badge, prompt: Text("W"))
                            .frame(maxWidth: 160)
                            .onChange(of: badge) { newValue in
                                if newValue.count > 2 {
                                    badge = String(newValue.prefix(2))
                                }
                            }
                        Spacer()
                        Toggle("Custom color", isOn: $useCustomBadgeColor)
                            .toggleStyle(.checkbox)
                        ColorPicker("", selection: $badgeColor, supportsOpacity: false)
                            .labelsHidden()
                            .disabled(!useCustomBadgeColor)
                    }
                    HStack {
                        Text("Icon")
                        Spacer()
                        Text(iconDescription)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { chooseIcon() }
                        // Pre-0.5 instances keep their (possibly badged) icon
                        // as-is until reset, so offer the reset there too.
                        if settings.customIconFile != nil || newIcon != nil
                            || (entry.manifest.settings == nil && !resetIcon) {
                            Button("Use App's Icon") {
                                newIcon = nil
                                resetIcon = true
                            }
                        }
                    }
                }

                Section("Isolation") {
                    if let cloneAssessment {
                        CloneToggle(isOn: $cloneApp, assessment: cloneAssessment)
                    }
                    Picker("Mode", selection: $mode) {
                        ForEach(RequestedMode.allCases, id: \.self) { candidate in
                            Text(label(for: candidate)).tag(candidate)
                        }
                    }
                    ForEach(recipeOptions) { option in
                        Toggle(isOn: Binding(
                            get: { activeOptions.contains(option.id) },
                            set: { enabled in
                                if enabled {
                                    activeOptions.insert(option.id)
                                } else {
                                    activeOptions.remove(option.id)
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                Text(option.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    TextEditor(text: $environmentText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 44)
                } header: {
                    Text("Extra environment")
                } footer: {
                    Text("One KEY=VALUE per line.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextEditor(text: $argumentsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 44)
                } header: {
                    Text("Extra launch arguments")
                } footer: {
                    Text("One argument per line, passed to the app after Parallex's own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if entry.running {
                    Label("Changes apply the next time the instance starts.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if working {
                    ProgressView().controlSize(.small)
                }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 520)
        .frame(minHeight: 420, maxHeight: 720)
        .onAppear(perform: load)
        .alert(
            "Could not save the instance",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(errorMessage ?? "") }
        )
    }

    private var iconDescription: String {
        if let newIcon {
            return newIcon.lastPathComponent
        }
        if resetIcon || (settings.customIconFile == nil && entry.manifest.settings != nil) {
            return "the app's icon"
        }
        return entry.manifest.settings == nil ? "current icon" : "custom"
    }

    private func label(for mode: RequestedMode) -> String {
        switch mode {
        case .auto: "Automatic (recommended)"
        case .dataDir: "App data directory"
        case .home: "Home isolation"
        case .launchOnly: "Launch only (no data isolation)"
        }
    }

    private func load() {
        name = entry.manifest.name
        badge = settings.badgeText ?? ""
        if let hex = settings.badgeColorHex, let color = NSColor(hex: hex) {
            useCustomBadgeColor = true
            badgeColor = Color(nsColor: color)
        } else {
            badgeColor = Color(nsColor: entry.color)
        }
        mode = settings.mode
        cloneApp = settings.isClone
        if let target = try? InstanceCreator.locateTarget(of: entry.manifest),
           let info = try? AppInspector.inspect(target) {
            cloneAssessment = AppCloner.assess(info)
        }
        activeOptions = settings.activeOptions(of: recipeOptions)
        environmentText = settings.extraEnvironment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        argumentsText = settings.extraArguments.joined(separator: "\n")
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Icon"
        panel.allowedContentTypes = [.icns, .png, .jpeg, .tiff, .heic]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        newIcon = url
        resetIcon = false
    }

    private func save() {
        var updated = settings
        let badgeText = badge.trimmingCharacters(in: .whitespaces)
        updated.badgeText = badgeText.isEmpty ? nil : badgeText
        updated.badgeColorHex = (useCustomBadgeColor && !badgeText.isEmpty)
            ? NSColor(badgeColor).hexString : nil
        updated.mode = mode
        updated.cloneApp = cloneApp ? true : nil
        if !recipeOptions.isEmpty {
            updated.enabledOptions = recipeOptions.map(\.id).filter(activeOptions.contains)
        }
        if resetIcon {
            updated.customIconFile = nil
        }

        var environment: [String: String] = [:]
        for line in environmentText.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let separator = trimmed.firstIndex(of: "="), separator != trimmed.startIndex else {
                errorMessage = "“\(trimmed)” isn't KEY=VALUE."
                return
            }
            environment[String(trimmed[..<separator])] = String(trimmed[trimmed.index(after: separator)...])
        }
        updated.extraEnvironment = environment
        updated.extraArguments = argumentsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let newName = name.trimmingCharacters(in: .whitespaces)
        let change = InstanceUpdate(
            name: newName == entry.manifest.name ? nil : newName,
            settings: updated,
            newCustomIcon: newIcon,
            resetIcon: resetIcon
        )
        working = true
        Task {
            do {
                try await model.update(entry, change)
                dismiss()
            } catch {
                errorMessage = "\(error)"
                working = false
            }
        }
    }
}
