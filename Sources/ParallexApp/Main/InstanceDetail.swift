import AppKit
import ParallexCore
import SwiftUI
import UniformTypeIdentifiers

/// Everything about one instance, editable in place. Changes that don't
/// touch the built app (open-at-start, color without a badge) save as you
/// make them; the rest collect in an apply bar, because applying rebuilds
/// the instance.
struct InstanceDetail: View {
    let entry: InstanceEntry
    @Environment(AppModel.self) private var model
    @State private var draft: InstanceDraft
    @State private var applying = false
    @State private var applyError: String?
    @State private var confirmRemove = false
    @State private var cloneAssessment: AppCloner.Assessment?
    @State private var targetSandboxed = false
    @State private var targetHasGroups = false
    /// The app has no Dock icon of its own (a menu bar app).
    @State private var targetIsAgent = false

    init(entry: InstanceEntry) {
        self.entry = entry
        _draft = State(initialValue: InstanceDraft(entry.manifest))
    }

    private var baseline: InstanceDraft { InstanceDraft(entry.manifest) }
    private var hasRebuildChanges: Bool { draft.requiresRebuild(from: baseline, manifest: entry.manifest) }
    private var blockedByRunningCopy: Bool {
        entry.running && (entry.isClone || draft.settings.isClone)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(entry: entry)
                    .padding(.bottom, Theme.Space.xl)
                ProblemBanners(entry: entry)
                if entry.manifest.isWeb {
                    WebsiteSection(entry: entry, draft: $draft)
                } else {
                    IsolationSection(
                        entry: entry, draft: $draft, cloneAssessment: cloneAssessment,
                        targetSandboxed: targetSandboxed, targetHasGroups: targetHasGroups
                    )
                }
                AppearanceSection(entry: entry, draft: $draft)
                LaunchSection(
                    entry: entry, openAtStart: $draft.settings.openAtLaunch.orFalse,
                    menuBarIcon: $draft.settings.menuBarIcon.orFalse, shortcut: $draft.settings.shortcut,
                    hideFromDock: draft.settings.isClone && !targetIsAgent ? hideFromDockBinding : nil
                )
                StorageSection(entry: entry)
                AdvancedSection(entry: entry, draft: $draft)
                RemoveFooter { confirmRemove = true }
            }
            .disabled(applying)
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.top, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xxxl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        #if DEBUG
        .defaultScrollAnchor(DebugRoute.scrollAnchor)
        #endif
        .navigationTitle("")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if hasRebuildChanges {
                ApplyBar(
                    applying: applying,
                    error: applyError,
                    blockedMessage: blockedByRunningCopy
                        ? "Quit \(entry.name) to apply — its copy of the app is rebuilt."
                        : draft.parsedEnvironment == nil ? "Fix the extra environment: each line needs KEY=VALUE."
                        : draft.invalidWebAddress ? "Type a web address, like web.whatsapp.com." : nil,
                    revert: revert,
                    apply: apply
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Theme.Motion.snappy, value: hasRebuildChanges)
        .onChange(of: draft.metadataSignature) { saveMetadataIfPossible() }
        // Changes held back while a rebuild was pending save once it isn't.
        .onChange(of: hasRebuildChanges) { _, pending in
            if !pending { saveMetadataIfPossible() }
        }
        .onChange(of: entry) { _, fresh in
            // Registry changed underneath (repair, CLI edit): reset unless
            // the user has pending rebuild edits.
            if !hasRebuildChanges {
                draft = InstanceDraft(fresh.manifest)
            }
        }
        .task(id: entry.manifest.targetApp) {
            let targetPath = entry.manifest.targetApp
            let inspected = await Task.detached {
                (try? AppInspector.inspect(URL(fileURLWithPath: targetPath))).map {
                    (AppCloner.assess($0), $0.isSandboxed, $0.isSandboxed && !AppCloner.appGroups(of: $0.url).isEmpty)
                }
            }.value
            cloneAssessment = inspected?.0
            targetSandboxed = inspected?.1 ?? false
            targetHasGroups = inspected?.2 ?? false
            targetIsAgent = NSDictionary(contentsOfFile: targetPath + "/Contents/Info.plist")?["LSUIElement"] as? Bool ?? false
        }
        .confirmationDialog("Remove “\(entry.name)”?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Move Instance and Its Data to Trash", role: .destructive) { model.remove(entry, keepData: false) }
            Button("Remove, Keep Data") { model.remove(entry, keepData: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(entry.running
                 ? "It's running — quit it first, or it keeps writing to data that's in the Trash."
                 : "Everything goes to the Trash, so you can still recover it.")
        }
    }

    /// Hiding a copy from the Dock leaves the menu bar icon or shortcut as
    /// the way back to it, so turning it on shows the menu bar icon too.
    private var hideFromDockBinding: Binding<Bool> {
        Binding(
            get: { draft.settings.hideFromDock == true },
            set: { hidden in
                draft.settings.hideFromDock = hidden ? true : nil
                if hidden, draft.settings.shortcut == nil {
                    draft.settings.menuBarIcon = true
                } else if !hidden {
                    // Undo what turning it on did, if that's all that changed.
                    draft.settings.menuBarIcon = baseline.settings.menuBarIcon
                }
            }
        )
    }

    private func revert() {
        withAnimation(Theme.Motion.snappy) {
            draft = baseline
            applyError = nil
        }
    }

    private func apply() {
        guard let change = draft.update(from: baseline) else { return }
        applying = true
        applyError = nil
        Task {
            do {
                let rebuilt = try await model.update(entry, change)
                // The rebuilt instance is the new baseline (clears a chosen
                // icon, reset flags, and anything the rebuild normalized).
                draft = InstanceDraft(rebuilt)
            } catch {
                applyError = "\(error)"
            }
            applying = false
        }
    }

    /// Save bookkeeping-only changes immediately (never while rebuild
    /// changes are pending — those save together on Apply). Only the fields
    /// that changed are carried onto the stored settings, and the draft is
    /// rebuilt from what was saved so the two can't drift apart.
    private func saveMetadataIfPossible() {
        guard !hasRebuildChanges, !applying else { return }
        let stored = entry.manifest.effectiveSettings
        var settings = stored
        settings.openAtLaunch = draft.settings.openAtLaunch
        settings.badgeColorHex = draft.settings.badgeColorHex
        settings.shortcut = draft.settings.shortcut
        settings.menuBarIcon = draft.settings.menuBarIcon
        guard settings != stored || entry.manifest.settings == nil else { return }
        if let saved = model.saveSettings(settings, for: entry) {
            var fresh = InstanceDraft(saved)
            fresh.environmentText = draft.environmentText
            fresh.argumentsText = draft.argumentsText
            draft = fresh
        }
    }
}

// MARK: - Draft

/// The editable state of an instance.
struct InstanceDraft: Equatable {
    var name: String
    var settings: InstanceSettings
    var newIcon: URL?
    var resetIcon = false
    var environmentText: String
    var argumentsText: String

    /// The color shown when none was chosen (derived from the slug).
    let defaultColorHex: String

    init(_ manifest: InstanceManifest) {
        name = manifest.name
        defaultColorHex = manifest.colorHex
        let settings = manifest.effectiveSettings
        self.settings = settings
        environmentText = settings.extraEnvironment.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        argumentsText = settings.extraArguments.joined(separator: "\n")
    }

    var colorHex: String { settings.badgeColorHex ?? defaultColorHex }

    /// Changes to fields that never need a rebuild on their own.
    var metadataSignature: [String] {
        [settings.openAtLaunch == true ? "1" : "0", settings.badgeColorHex ?? "", settings.shortcut?.displayString ?? "",
         settings.menuBarIcon == true ? "1" : "0"]
    }

    var parsedEnvironment: [String: String]? {
        var environment: [String: String] = [:]
        for line in environmentText.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let separator = trimmed.firstIndex(of: "="), separator != trimmed.startIndex else {
                return nil
            }
            environment[String(trimmed[..<separator])] = String(trimmed[trimmed.index(after: separator)...])
        }
        return environment
    }

    /// A web instance's address, typed but not (yet) a web address.
    var invalidWebAddress: Bool {
        settings.webURL.map { WebShell.normalizedURL($0) == nil } ?? false
    }

    var parsedArguments: [String] {
        argumentsText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The settings this draft describes.
    var resolvedSettings: InstanceSettings {
        var resolved = settings
        resolved.extraEnvironment = parsedEnvironment ?? settings.extraEnvironment
        resolved.extraArguments = parsedArguments
        let badge = (resolved.badgeText ?? "").trimmingCharacters(in: .whitespaces)
        resolved.badgeText = badge.isEmpty ? nil : String(badge.prefix(2))
        if resetIcon {
            resolved.customIconFile = nil
        }
        // Only a copy can leave the Dock; don't keep it for a plain instance.
        if !resolved.isClone {
            resolved.hideFromDock = nil
        }
        if let web = resolved.webURL, let url = WebShell.normalizedURL(web) {
            resolved.webURL = url.absoluteString
        }
        return resolved
    }

    func requiresRebuild(from baseline: InstanceDraft, manifest: InstanceManifest) -> Bool {
        name.trimmingCharacters(in: .whitespaces) != manifest.name
            || newIcon != nil || resetIcon
            // Unfinished environment text is a pending edit, not "no change".
            || parsedEnvironment == nil || invalidWebAddress
            || baseline.resolvedSettings.requiresRebuild(toReach: resolvedSettings)
    }

    func update(from baseline: InstanceDraft) -> InstanceUpdate? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return InstanceUpdate(
            name: trimmed == baseline.name ? nil : trimmed,
            settings: resolvedSettings,
            newCustomIcon: newIcon,
            resetIcon: resetIcon
        )
    }
}

extension Binding where Value == Bool? {
    /// Treat an optional flag as a plain toggle (nil = off).
    var orFalse: Binding<Bool> {
        Binding<Bool>(get: { wrappedValue == true }, set: { wrappedValue = $0 ? true : nil })
    }
}

// MARK: - Header

private struct DetailHeader: View {
    let entry: InstanceEntry
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            InstanceGlyph(iconPath: entry.iconPath, color: entry.color, size: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.name)
                    .font(Theme.Font.display)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    StatusPill(state: entry.runState)
                    Text("·").foregroundStyle(.tertiary)
                    Text(entry.manifest.isWeb ? "Website · \(entry.targetName)"
                         : entry.isClone ? "Own copy of \(entry.targetName)" : "Instance of \(entry.targetName)")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Theme.Space.l)
            if model.busy.contains(entry.id) {
                ProgressView().controlSize(.small)
            }
            Button(entry.running ? "Show" : "Open") { model.activate(entry) }
                .buttonStyle(.primary)
                .disabled(!entry.status.canLaunch)
                .keyboardShortcut("o", modifiers: .command)
            Menu {
                if let site = entry.manifest.webURL {
                    Button("Open \(entry.targetName) in Browser") { NSWorkspace.shared.open(site) }
                } else {
                    Button("Open Original \(entry.targetName)") { model.launchOriginal(entry) }
                }
                Divider()
                Button("Export…") { model.export(entry) }
                    .disabled(entry.running)
                Button("Duplicate") { model.duplicate(entry, includeData: false) }
                Button("Duplicate with Data") { model.duplicate(entry, includeData: true) }
                    .disabled(entry.running || entry.manifest.clone?.usesLauncher == false)
                    .help(entry.manifest.clone?.usesLauncher == false
                          ? "Its data is in its own sandbox container, which can't be copied"
                          : entry.running ? "Quit it first so its data is copied consistently"
                          : "Starts where this one is — signed in, same history")
                Divider()
                Button("Show in Finder") { model.reveal(entry.manifest.wrapperPath) }
                Button("Show Data Folder") { model.revealData(entry) }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ParallexLink.url(opening: entry.name).absoluteString, forType: .string)
                }
                .help("A parallex:// link that opens this instance from Shortcuts, launchers or scripts")
                Button("Report How It Works…") { NSWorkspace.shared.open(CompatibilityReport.url(for: entry.manifest)) }
                    .help("Opens a report on GitHub with the app, its version and how this instance was made filled in. Nothing is sent until you submit it.")
                Divider()
                Button("Repair") { model.repair(entry) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(.secondary)
            .foregroundStyle(.secondary)
            .fixedSize()
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.55), in: .rect(cornerRadius: Theme.Radius.control))
            .accessibilityLabel("More actions")
        }
    }
}

// MARK: - Problems

private struct ProblemBanners: View {
    let entry: InstanceEntry
    @Environment(AppModel.self) private var model

    private var separationInactive: Bool {
        if case .report(let report) = model.isolation[entry.id] { return report.separationInactive }
        return false
    }

    private var leakMessage: String {
        separationInactive
            ? "macOS didn't load what keeps \(entry.name)'s data separate, so it's using \(entry.targetName)'s. Restart it to try again."
            : "\(entry.name) has files of \(entry.targetName)'s own open — its data isn't fully separate. See Isolation below for which."
    }

    var body: some View {
        if model.leaking.contains(entry.id) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Theme.failure)
                Text(leakMessage)
                    .font(Theme.Font.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.m)
                if separationInactive {
                    Button("Restart") { model.restart(entry) }.buttonStyle(.secondary)
                } else {
                    Button("Check Again") { model.verifyIsolation(entry) }.buttonStyle(.secondary)
                }
            }
            .padding(Theme.Space.m)
            .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.tile))
            .padding(.bottom, Theme.Space.m)
        }
        if model.quickExits.contains(entry.id) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.attention)
                Text("\(entry.name) quit right after it opened. Some App Store apps check their purchase receipt, "
                     + "or refuse a changed signature, and won't run as their own copy — turn off Own identity below to run it as an instance instead.")
                    .font(Theme.Font.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.m)
                Button("Open Again") {
                    model.dismissQuickExit(entry)
                    model.launch(entry)
                }
                .buttonStyle(.secondary)
            }
            .padding(Theme.Space.m)
            .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.tile))
            .padding(.bottom, Theme.Space.m)
        }
        ForEach(Array(entry.status.problems.enumerated()), id: \.offset) { _, problem in
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Image(systemName: icon(for: problem))
                    .foregroundStyle(problem.isBlocking || problem == .separationUnavailable ? Theme.failure : Theme.attention)
                Text(message(for: problem))
                    .font(Theme.Font.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.m)
                action(for: problem)
            }
            .padding(Theme.Space.m)
            .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.tile))
            .padding(.bottom, Theme.Space.m)
        }
    }

    private func icon(for problem: InstanceStatus.Problem) -> String {
        if problem.isBlocking || problem == .separationUnavailable { return "exclamationmark.octagon.fill" }
        return "arrow.triangle.2.circlepath"
    }

    private func message(for problem: InstanceStatus.Problem) -> String {
        switch problem {
        case .wrapperMissing: "The instance app is missing. Repair rebuilds it — its data is safe."
        case .targetMissing: "\(entry.targetName) isn't installed anymore. Reinstall it, or point the instance at where it is now."
        case .targetMoved(let path): "\(entry.targetName) moved to \(Paths.abbreviate(path)). Repair records the new location."
        case .wrapperOutdated: "Built with an older Parallex. Repair picks up the latest improvements."
        case .cloneOutdated(_, let original) where entry.running:
            "\(entry.targetName) updated to \(original). This copy catches up when it restarts."
        case .cloneOutdated(_, let original): "\(entry.targetName) updated to \(original). Repair refreshes this copy."
        case .separationUnavailable:
            "macOS didn't let Parallex give \(entry.name) a Library of its own, so it didn't open — it would have used \(entry.targetName)'s data. "
                + "Try again after a macOS or Parallex update, or use it as a plain copy that shares \(entry.targetName)'s data."
        }
    }

    @ViewBuilder private func action(for problem: InstanceStatus.Problem) -> some View {
        if case .targetMissing = problem {
            Button("Locate…") { locate() }.buttonStyle(.secondary)
        } else if case .separationUnavailable = problem {
            HStack(spacing: Theme.Space.s) {
                Button("Try Again") { model.launch(entry) }.buttonStyle(.secondary)
                Button("Use as Plain Copy") { model.useAsPlainCopy(entry) }.buttonStyle(.secondary)
            }
        } else if entry.running, entry.isClone, problem.isMaintainable {
            // A running copy can't be rebuilt underneath itself.
            Button("Restart to Update") { model.restart(entry) }.buttonStyle(.secondary)
        } else {
            Button("Repair") { model.repair(entry) }.buttonStyle(.secondary)
        }
    }

    private func locate() {
        let panel = NSOpenPanel()
        panel.title = "Where is \(entry.targetName) now?"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            model.repair(entry, targetApp: url)
        }
    }
}

// MARK: - Website

private struct WebsiteSection: View {
    let entry: InstanceEntry
    @Binding var draft: InstanceDraft

    var body: some View {
        DetailSection(title: "Website", subtitle: "Its own sign-in, cookies, and notifications — separate from your browser and every other instance.") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Address").font(Theme.Font.callout.weight(.medium))
                TextField("web.whatsapp.com", text: Binding(
                    get: { draft.settings.webURL ?? "" },
                    set: { draft.settings.webURL = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
                Text(draft.invalidWebAddress ? "Type a web address, like web.whatsapp.com." : "Where it opens. Links to other sites open in your browser.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(draft.invalidWebAddress ? Theme.failure : Color.secondary)
            }
        }
    }
}

// MARK: - Isolation

private struct IsolationSection: View {
    let entry: InstanceEntry
    @Binding var draft: InstanceDraft
    let cloneAssessment: AppCloner.Assessment?
    let targetSandboxed: Bool
    let targetHasGroups: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        DetailSection(title: "Isolation", subtitle: summary) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if let cloneAssessment {
                    ExplainedToggle(
                        title: "Own identity",
                        detail: cloneAssessment.possible
                            ? "Runs as its own copy of \(entry.targetName): its own Dock icon, notifications, and permissions."
                            : cloneAssessment.notes.first ?? "Not possible for this app.",
                        isOn: $draft.settings.cloneApp.orFalse
                    )
                    .disabled(!cloneAssessment.possible)
                }
                if draft.settings.isClone, !targetSandboxed {
                    ExplainedToggle(
                        title: "Separate Library",
                        detail: "Everything \(entry.targetName) keeps in ~/Library — sign-ins, caches, web storage — stays in this instance. Your documents and other folders stay shared.",
                        isOn: separateLibraryBinding
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    // Home mode gives the copy a home of its own already.
                    if draft.settings.separateLibrary != false, entry.manifest.mode != .home {
                        ExplainedToggle(
                            title: "Separate hidden folders",
                            detail: "Folders \(entry.targetName) keeps in your home folder\(hiddenFolderExample) stay in this instance too. Everything else there, like your other tools' settings, is shared.",
                            isOn: separateHiddenFoldersBinding
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                } else if draft.settings.isClone, targetHasGroups {
                    ExplainedToggle(
                        title: "Separate shared data",
                        detail: "\(entry.targetName) keeps its sign-in and data in containers shared across the developer's apps. This copy gets its own.",
                        isOn: separateLibraryBinding
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if entry.manifest.redirectedHome != nil, draft.settings.separateLibrary != false {
                    StartFromOriginalRow(entry: entry)
                }
                ForEach(entry.manifest.recipe?.options ?? []) { option in
                    ExplainedToggle(title: option.title, detail: option.detail, isOn: optionBinding(option))
                }
                VerifyRow(entry: entry)
            }
        }
    }

    /// On unless turned off; switching back on restores "default" when that's
    /// what's stored, so it doesn't count as a change.
    private var separateLibraryBinding: Binding<Bool> {
        Binding(
            get: { draft.settings.separateLibrary != false },
            set: { on in
                let stored = entry.manifest.effectiveSettings.separateLibrary
                draft.settings.separateLibrary = on ? (stored == nil ? nil : true) : false
            }
        )
    }

    private var separateHiddenFoldersBinding: Binding<Bool> {
        Binding(
            get: { draft.settings.separateHiddenFolders != false },
            set: { on in
                let stored = entry.manifest.effectiveSettings.separateHiddenFolders
                draft.settings.separateHiddenFolders = on ? (stored == nil ? nil : true) : false
            }
        )
    }

    /// ", like ~/.vscode", from what the copy keeps to itself.
    private var hiddenFolderExample: String {
        guard let first = entry.manifest.privateHomeItems?.first(where: { !$0.contains("/") }) else { return "" }
        return ", like ~/\(first)"
    }

    private var summary: String {
        let manifest = entry.manifest
        if manifest.redirectedHome != nil {
            return "Runs as its own app with its own Library, so nothing it keeps there is shared with \(entry.targetName)."
        }
        if manifest.separatedGroups != nil {
            return "Runs as its own app with its own containers, shared ones included — separate from \(entry.targetName)."
        }
        let identity = manifest.clone != nil ? "Runs as its own app. " : ""
        switch manifest.mode {
        case .dataDir:
            if manifest.recipe != nil, manifest.preset == manifest.recipe?.id {
                return identity + "Its own sign-in and data, using \(entry.targetName)'s own settings for it."
            }
            return identity + "Its own sign-in and data, in a separate data folder."
        case .home:
            return identity + "Its own home folder for settings and command-line tools. Some app data may still be shared on recent macOS."
        case .launchOnly:
            return manifest.clone != nil
                ? "Runs as its own app with its own sandbox container."
                : "A separate launcher only — it shares \(entry.targetName)'s data."
        }
    }

    private func optionBinding(_ option: RecipeOption) -> Binding<Bool> {
        let available = entry.manifest.recipe?.options ?? []
        return Binding(
            get: { draft.settings.activeOptions(of: available).contains(option.id) },
            set: { draft.settings.setOption(option.id, enabled: $0, available: available) }
        )
    }
}

/// Seed an own-identity copy with the original's data (it starts empty).
private struct StartFromOriginalRow: View {
    let entry: InstanceEntry
    @Environment(AppModel.self) private var model
    @State private var items: [OriginalData.Item] = []
    @State private var confirming = false

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Start from \(entry.targetName)'s data").font(Theme.Font.body)
                Text(items.isEmpty
                     ? "Nothing of \(entry.targetName)'s to copy right now."
                     : "Copies its settings, library and sign-ins into this instance, then the two go their own ways.")
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.l)
            Button("Copy…") { confirming = true }
                .buttonStyle(.secondary)
                .disabled(items.isEmpty || entry.running || model.busy.contains(entry.id))
        }
        .task(id: entry.manifest.redirectedHome) {
            let manifest = entry.manifest
            items = await Task.detached { OriginalData.plan(for: manifest) }.value
        }
        .confirmationDialog(
            "Replace \(entry.name)'s data with \(entry.targetName)'s?",
            isPresented: $confirming, titleVisibility: .visible
        ) {
            Button("Copy \(entry.targetName)'s Data") { model.copyOriginalData(into: entry) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Copies \(items.map(\.label).joined(separator: ", ")). What this instance has there now goes to the Trash. Sign-ins \(entry.targetName) keeps in the keychain may need signing in again.")
        }
    }
}

private struct VerifyRow: View {
    let entry: InstanceEntry
    @Environment(AppModel.self) private var model
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                Button("Verify Isolation") { model.verifyIsolation(entry) }
                    .buttonStyle(.secondary)
                    .disabled(!entry.running || isChecking)
                    .help(entry.running ? "Look at the files it has open right now" : "Open the instance first")
                result
                Spacer(minLength: 0)
            }
            if showDetails, case .report(let report) = model.isolation[entry.id] {
                ReportDetails(report: report)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Theme.Motion.snappy, value: showDetails)
    }

    private var isChecking: Bool {
        if case .checking = model.isolation[entry.id] { return true }
        return false
    }

    @ViewBuilder private var result: some View {
        switch model.isolation[entry.id] {
        case .none:
            Text(entry.running ? "Checks the files it has open right now." : "Open it to verify.")
                .font(Theme.Font.callout)
                .foregroundStyle(.tertiary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking open files…").font(Theme.Font.callout).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message).font(Theme.Font.callout).foregroundStyle(.secondary).lineLimit(2)
        case .report(let report):
            Button {
                showDetails.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: report.isClean ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(report.isClean ? Theme.running : Theme.failure)
                        .symbolEffect(.bounce, value: report.findings.count)
                    Text(report.isClean
                         ? "No leaks — \(report.findings(in: .isolated).count) open files, all its own."
                         : "Using \(entry.targetName)'s own data")
                        .font(Theme.Font.callout.weight(.medium))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showDetails ? 90 : 0))
                }
            }
            .buttonStyle(.plain)
        }
    }
}

private struct ReportDetails: View {
    let report: IsolationReport

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            group(.leak, "Using the original's data", Theme.failure)
            group(.sharedByIdentity, "Shared, can't be separated", .secondary)
            group(.sharedByChoice, "Shared on purpose", .secondary)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.tile))
    }

    @ViewBuilder private func group(_ category: IsolationReport.Category, _ title: String, _ color: Color) -> some View {
        let findings = report.findings(in: category)
        if !findings.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.Font.caption.weight(.semibold)).foregroundStyle(color)
                ForEach(findings, id: \.path) { finding in
                    Text(Paths.abbreviate(finding.path))
                        .font(Theme.Font.mono)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(finding.reason)
                }
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceSection: View {
    let entry: InstanceEntry
    @Binding var draft: InstanceDraft
    @State private var fetchingSiteIcon = false

    var body: some View {
        DetailSection(title: "Appearance") {
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                BadgedIconPreview(
                    iconPath: previewIconPath,
                    badge: (draft.settings.badgeText ?? "").trimmingCharacters(in: .whitespaces),
                    color: Color(hex: draft.colorHex),
                    size: 76
                )
                .instanceRing(Color(hex: draft.colorHex), size: 76)
                .padding(.top, 2)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.m) {
                    GridRow {
                        label("Name")
                        TextField("Name", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                    }
                    GridRow(alignment: .center) {
                        label("Color")
                        ColorSwatchPicker(selection: colorBinding, palette: IconBuilder.palette)
                    }
                    GridRow {
                        label("Badge")
                        HStack(spacing: Theme.Space.s) {
                            TextField("None", text: badgeBinding)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 64)
                            Text("1–2 letters on the icon")
                                .font(Theme.Font.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    GridRow {
                        label("Icon")
                        HStack(spacing: Theme.Space.s) {
                            Button("Choose…", action: chooseIcon).buttonStyle(.secondary)
                            if entry.manifest.isWeb {
                                // Parallex Web's own icon means nothing here.
                                Button("Use Site Icon", action: useSiteIcon)
                                    .buttonStyle(.secondary)
                                    .disabled(fetchingSiteIcon || draft.invalidWebAddress)
                                    .help("Get the icon of the site it opens again")
                                if fetchingSiteIcon {
                                    ProgressView().controlSize(.small)
                                }
                            } else if hasCustomIcon {
                                Button("Use App Icon") {
                                    draft.newIcon = nil
                                    draft.resetIcon = true
                                }
                                .buttonStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.callout)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    /// The site's icon (or its letter tile), for the address being edited.
    private func useSiteIcon() {
        guard let site = draft.settings.webURL.flatMap(WebShell.normalizedURL) else { return }
        let name = draft.name
        let color = draft.colorHex
        fetchingSiteIcon = true
        Task {
            let icon = await Task.detached(priority: .userInitiated) {
                WebIcon.fetch(for: site) ?? WebIcon.monogram(for: name, colorHex: color)
            }.value
            fetchingSiteIcon = false
            if let icon {
                draft.newIcon = icon
                draft.resetIcon = false
            }
        }
    }

    private var colorBinding: Binding<String> {
        Binding(get: { draft.colorHex },
                set: { draft.settings.badgeColorHex = $0 })
    }

    private var badgeBinding: Binding<String> {
        Binding(get: { draft.settings.badgeText ?? "" },
                set: { value in
                    let trimmed = String(value.prefix(2))
                    draft.settings.badgeText = trimmed.isEmpty ? nil : trimmed
                })
    }

    private var hasCustomIcon: Bool {
        draft.newIcon != nil || (!draft.resetIcon && (draft.settings.customIconFile != nil || entry.manifest.settings == nil))
    }

    /// What the icon will be drawn on: a newly chosen file, the stored custom
    /// icon, or the app's own.
    private var previewIconPath: String {
        if let newIcon = draft.newIcon {
            return newIcon.path
        }
        if !draft.resetIcon, let file = draft.settings.customIconFile {
            return Paths.instanceDir(slug: entry.id).appendingPathComponent(file).path
        }
        return draft.resetIcon || entry.manifest.settings != nil ? entry.manifest.targetApp : entry.iconPath
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Icon"
        panel.allowedContentTypes = [.icns, .png, .jpeg, .tiff, .heic]
        if panel.runModal() == .OK, let url = panel.url {
            draft.newIcon = url
            draft.resetIcon = false
        }
    }
}

// MARK: - Launch

private struct LaunchSection: View {
    let entry: InstanceEntry
    @Binding var openAtStart: Bool
    @Binding var menuBarIcon: Bool
    @Binding var shortcut: KeyShortcut?
    /// Only for own-identity copies (a plain instance is the original app
    /// as far as the Dock knows).
    var hideFromDock: Binding<Bool>?
    @Environment(AppModel.self) private var model

    var body: some View {
        DetailSection(title: "Launch") {
            ExplainedToggle(
                title: "Open when Parallex starts",
                detail: "With Parallex opening at login, this instance is ready when you are.",
                isOn: $openAtStart
            )
            ExplainedToggle(
                title: "Show in the menu bar",
                detail: "Its icon up top opens \(entry.name), brings it forward, or hides it when it's in front.",
                isOn: $menuBarIcon
            )
            HStack(alignment: .center, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keyboard shortcut").font(Theme.Font.body)
                    Text(shortcutDetail)
                        .font(Theme.Font.callout)
                        .foregroundStyle(unavailable ? Theme.attention : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.l)
                ShortcutRecorder(shortcut: $shortcut) { candidate in
                    model.shortcutConflict(candidate, for: entry.id)
                }
            }
            if let hideFromDock {
                ExplainedToggle(
                    title: "Hide from the Dock",
                    detail: "No Dock icon or ⌘-Tab entry, and its menus don't show. Open it from its menu bar icon or shortcut. Takes effect the next time it opens.",
                    isOn: hideFromDock
                )
            }
        }
    }

    private var unavailable: Bool {
        shortcut != nil && model.unavailableShortcuts.contains(entry.id)
    }

    private var shortcutDetail: String {
        if unavailable {
            return "Another app already uses this shortcut. Record a different one."
        }
        return "Opens \(entry.name) from anywhere, brings it forward, or hides it when it's in front."
    }
}

// MARK: - Storage

private struct StorageSection: View {
    let entry: InstanceEntry
    @Environment(AppModel.self) private var model

    var body: some View {
        DetailSection(title: "Storage") {
            if let report = model.storage[entry.id] {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Text(InstanceStorage.format(report.totalBytes))
                            .font(Theme.Font.title)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("on disk").font(Theme.Font.callout).foregroundStyle(.secondary)
                    }
                    StorageBar(total: report.totalBytes, caches: report.cacheBytes, unused: report.unusedBytes)
                    HStack(spacing: Theme.Space.s) {
                        Button("Clear Caches · \(InstanceStorage.format(report.cacheBytes))") {
                            model.reclaim(.caches, of: entry)
                        }
                        .buttonStyle(.secondary)
                        .disabled(entry.running || report.caches.isEmpty)
                        if !report.unused.isEmpty {
                            Button("Remove Leftovers · \(InstanceStorage.format(report.unusedBytes))") {
                                model.reclaim(.unused, of: entry)
                            }
                            .buttonStyle(.secondary)
                            .disabled(entry.running)
                        }
                        Button("Show Data Folder") { model.revealData(entry) }
                            .buttonStyle(.secondary)
                    }
                    if entry.running && !report.caches.isEmpty {
                        Text("Quit the instance to clear its caches.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .animation(Theme.Motion.snappy, value: report.totalBytes)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Measuring…").font(Theme.Font.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Total usage as one bar: data, caches, and leftovers.
private struct StorageBar: View {
    let total: Int64
    let caches: Int64
    let unused: Int64

    var body: some View {
        let safeTotal = max(total, 1)
        let data = max(total - caches - unused, 0)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    segment(Color(nsColor: .secondaryLabelColor), data, safeTotal, proxy.size.width)
                    segment(Color(nsColor: .tertiaryLabelColor), caches, safeTotal, proxy.size.width)
                    segment(Theme.attention, unused, safeTotal, proxy.size.width)
                }
            }
            .frame(height: 6)
            .clipShape(.capsule)
            HStack(spacing: Theme.Space.l) {
                legend(Color(nsColor: .secondaryLabelColor), "Data", data)
                legend(Color(nsColor: .tertiaryLabelColor), "Caches", caches)
                if unused > 0 {
                    legend(Theme.attention, "Leftovers", unused)
                }
            }
        }
        .frame(maxWidth: 440)
    }

    private func segment(_ color: Color, _ bytes: Int64, _ total: Int64, _ width: CGFloat) -> some View {
        color.frame(width: bytes > 0 ? max(3, width * CGFloat(bytes) / CGFloat(total)) : 0)
    }

    private func legend(_ color: Color, _ title: String, _ bytes: Int64) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(Theme.Font.caption).foregroundStyle(.secondary)
            Text(InstanceStorage.format(bytes)).font(Theme.Font.caption).monospacedDigit()
        }
    }
}

// MARK: - Advanced

private struct AdvancedSection: View {
    let entry: InstanceEntry
    @Binding var draft: InstanceDraft
    @State private var expanded = false

    var body: some View {
        DetailSection(title: "Advanced") {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if !entry.manifest.isWeb {
                        Picker("Isolation mode", selection: $draft.settings.mode) {
                            Text("Automatic").tag(RequestedMode.auto)
                            Text("App data folder").tag(RequestedMode.dataDir)
                            Text("Home folder").tag(RequestedMode.home)
                            Text("Launch only").tag(RequestedMode.launchOnly)
                        }
                        .frame(maxWidth: 320)
                    }
                    editor("Extra environment", "One KEY=VALUE per line.", text: $draft.environmentText,
                           invalid: draft.parsedEnvironment == nil)
                    editor("Extra launch arguments", "One per line, after Parallex's own.", text: $draft.argumentsText,
                           invalid: false)
                    VStack(alignment: .leading, spacing: 6) {
                        FactRow(label: "Data", value: Paths.abbreviate(Paths.instanceDir(slug: entry.id).path), mono: true)
                        FactRow(label: "App", value: Paths.abbreviate(entry.manifest.wrapperPath), mono: true)
                        FactRow(label: "Bundle ID", value: entry.manifest.clone?.bundleIdentifier ?? entry.manifest.bundleIdentifier, mono: true)
                        FactRow(label: "Created", value: entry.manifest.createdAt.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                .padding(.top, Theme.Space.m)
            } label: {
                Text("Mode, environment, arguments, and paths")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
                    .contentShape(.rect)
                    .onTapGesture { withAnimation(Theme.Motion.snappy) { expanded.toggle() } }
            }
        }
    }

    private func editor(_ title: String, _ hint: String, text: Binding<String>, invalid: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.Font.callout.weight(.medium))
            TextEditor(text: text)
                .font(Theme.Font.mono)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 64)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: Theme.Radius.control))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .strokeBorder(invalid ? Theme.failure : Theme.hairline)
                )
            Text(invalid ? "Each line needs KEY=VALUE." : hint)
                .font(Theme.Font.caption)
                .foregroundStyle(invalid ? Theme.failure : Color.secondary)
        }
    }
}

// MARK: - Remove

private struct RemoveFooter: View {
    let action: () -> Void

    var body: some View {
        HStack {
            Button(role: .destructive, action: action) {
                Text("Remove Instance…").font(Theme.Font.body.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.failure)
            Spacer()
        }
        .padding(.top, Theme.Space.xl)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

// MARK: - Apply bar

private struct ApplyBar: View {
    let applying: Bool
    let error: String?
    let blockedMessage: String?
    let revert: () -> Void
    let apply: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: error == nil ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill")
                .foregroundStyle(error == nil ? Color.secondary : Theme.failure)
            Text(error ?? blockedMessage ?? "Applying rebuilds the instance. It takes effect the next time it opens.")
                .font(Theme.Font.callout)
                .foregroundStyle(error == nil ? Color.secondary : Theme.failure)
                .lineLimit(2)
            Spacer(minLength: Theme.Space.m)
            Button("Revert", action: revert)
                .buttonStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            Button(action: apply) {
                if applying {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Text("Apply")
                }
            }
            .buttonStyle(.primary)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(applying || blockedMessage != nil)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.m)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}
