import AppKit
import SwiftUI
import ParallexCore
import UniformTypeIdentifiers

/// The "New Instance" flow: pick an app, see what Parallex will do with it
/// (framework, sandbox verdict, recommended isolation), tune name/badge/mode,
/// create.
struct CreateSheet: View {
    @EnvironmentObject private var model: InstancesModel
    @Environment(\.dismiss) private var dismiss

    @State private var appURL: URL?
    @State private var probe: AppProbe?
    @State private var probing = false

    @State private var name = ""
    @State private var badge = ""
    @State private var useCustomBadgeColor = false
    @State private var badgeColor = Color(red: 0.37, green: 0.36, blue: 0.90)
    @State private var mode: RequestedMode = .auto
    @State private var launchAfterCreate = true
    @State private var activeOptions: Set<String> = []
    @State private var adoptFolder: URL?
    @State private var cloneApp = false

    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                appSection
                if probe != nil {
                    instanceSection
                    notesSection
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 480)
        .frame(minHeight: 280, maxHeight: 640)
        .alert(
            "Could not create the instance",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(errorMessage ?? "") }
        )
    }

    // MARK: - Sections

    private var appSection: some View {
        Section("App") {
            HStack(spacing: 10) {
                if let appURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                        .resizable()
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(probe?.name ?? appURL.deletingPathExtension().lastPathComponent)
                            .font(.headline)
                        if let probe {
                            Text("\(probe.frameworkDisplayName)\(probe.sandboxed ? " · sandboxed" : "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                    Text("Choose the app to duplicate")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if probing {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(appURL == nil ? "Choose App…" : "Change…") {
                    chooseApp()
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var instanceSection: some View {
        Section("Instance") {
            TextField("Name", text: $name, prompt: Text("Claude Work"))

            HStack {
                TextField("Icon badge", text: $badge, prompt: Text("W"))
                    .frame(maxWidth: 160)
                    .onChange(of: badge) { newValue in
                        // 1–2 characters, drawn onto the icon.
                        if newValue.count > 2 {
                            badge = String(newValue.prefix(2))
                        }
                    }
                Spacer()
                Toggle("Custom color", isOn: $useCustomBadgeColor)
                    .toggleStyle(.checkbox)
                    .disabled(badge.isEmpty)
                ColorPicker("", selection: $badgeColor, supportsOpacity: false)
                    .labelsHidden()
                    .disabled(!useCustomBadgeColor || badge.isEmpty)
            }

            Picker("Isolation", selection: $mode) {
                ForEach(RequestedMode.allCases, id: \.self) { candidate in
                    Text(label(for: candidate)).tag(candidate)
                }
            }

            if let probe {
                CloneToggle(isOn: $cloneApp, assessment: probe.cloneAssessment)
            }

            ForEach(probe?.recipeOptions ?? []) { option in
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

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start from existing data")
                    Text(adoptFolder.map { Paths.abbreviate($0.path) }
                         ?? "Optional: move in a profile folder (e.g. an old --user-data-dir) to keep its sign-in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if adoptFolder != nil {
                    Button("Clear") { adoptFolder = nil }
                }
                Button("Choose…") { chooseAdoptFolder() }
            }

            Toggle("Launch after creating", isOn: $launchAfterCreate)
        }
    }

    private var notesSection: some View {
        Section {
            if let probe {
                ForEach(probe.notes, id: \.self) { note in
                    Label {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if working {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 6)
            }
            Button("Create Instance") { create() }
                .keyboardShortcut(.defaultAction)
                .disabled(appURL == nil || probe == nil || working
                    || name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
    }

    // MARK: - Actions

    private func label(for mode: RequestedMode) -> String {
        switch mode {
        case .auto:
            if let probe {
                return "Automatic — \(probe.recommendedMode.rawValue) (recommended)"
            }
            return "Automatic (recommended)"
        case .dataDir: return "App data directory"
        case .home: return "Home isolation"
        case .launchOnly: return "Launch only (no data isolation)"
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        select(url)
    }

    private func chooseAdoptFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Profile Folder to Move In"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        adoptFolder = url
    }

    private func select(_ url: URL) {
        appURL = url
        probe = nil
        probing = true
        Task {
            do {
                let result = try await model.probeApp(at: url)
                if result.isParallexWrapper {
                    appURL = nil
                    errorMessage = "“\(result.name)” is itself a Parallex instance — choose the original app instead."
                } else {
                    probe = result
                    name = result.suggestedName
                    mode = .auto
                    activeOptions = Set(result.recipeOptions.filter(\.defaultEnabled).map(\.id))
                    cloneApp = false
                }
            } catch {
                appURL = nil
                errorMessage = "\(error)"
            }
            probing = false
        }
    }

    private func create() {
        guard let appURL else { return }
        working = true
        var request = CreateRequest(appReference: appURL.path)
        request.name = name.trimmingCharacters(in: .whitespaces)
        request.mode = mode
        request.adoptData = adoptFolder
        request.cloneApp = cloneApp
        if let options = probe?.recipeOptions, !options.isEmpty {
            request.enabledOptions = options.map(\.id).filter(activeOptions.contains)
        }
        let badgeText = badge.trimmingCharacters(in: .whitespaces)
        if !badgeText.isEmpty {
            request.badgeText = badgeText
            if useCustomBadgeColor {
                request.badgeColorHex = NSColor(badgeColor).hexString
            }
        }
        Task {
            do {
                let result = try await model.create(request)
                if launchAfterCreate {
                    model.launch(InstancesModel.Entry(
                        manifest: result.manifest,
                        status: InstanceStatus.check(result.manifest)
                    ))
                }
                dismiss()
            } catch {
                errorMessage = "\(error)"
                working = false
            }
        }
    }
}
