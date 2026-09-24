import AppKit
import Observation
import ParallexCore
import SwiftUI
import UniformTypeIdentifiers

/// One instance as the UI sees it: its manifest plus live status.
struct InstanceEntry: Identifiable, Equatable {
    let manifest: InstanceManifest
    let status: InstanceStatus

    var id: String { manifest.slug }
    var name: String { manifest.name }
    var running: Bool { status.running }
    var pid: pid_t? { status.pid }
    var color: Color { Color(hex: manifest.colorHex) }
    var nsColor: NSColor { NSColor(hex: manifest.colorHex) ?? .systemBlue }
    var targetName: String { URL(fileURLWithPath: manifest.targetApp).deletingPathExtension().lastPathComponent }
    var isClone: Bool { manifest.clone != nil }

    /// The wrapper's (possibly badged) icon, or the app's if the wrapper is gone.
    var iconPath: String {
        FileManager.default.fileExists(atPath: manifest.wrapperPath) ? manifest.wrapperPath : manifest.targetApp
    }

    var needsRepair: Bool {
        status.problems.contains {
            switch $0 {
            case .targetMissing, .separationUnavailable: false
            default: true
            }
        }
    }

    var runState: RunState {
        if let blocking = status.problems.first(where: \.isBlocking) {
            return .broken(blocking == .wrapperMissing ? "Needs repair" : "App missing")
        }
        if running {
            return .running
        }
        if status.problems.contains(.separationUnavailable) {
            return .attention("Can't separate")
        }
        if !status.problems.isEmpty {
            return .attention("Update available")
        }
        return .stopped
    }

    static func == (lhs: InstanceEntry, rhs: InstanceEntry) -> Bool {
        lhs.id == rhs.id && lhs.pid == rhs.pid && lhs.status.problems == rhs.status.problems
            && lhs.manifest.name == rhs.manifest.name && lhs.manifest.settings == rhs.manifest.settings
            && lhs.manifest.wrapperPath == rhs.manifest.wrapperPath
    }
}

/// The app's state. Reads the instance registry, tracks which instances run
/// and which one is in front, and runs the (blocking) core operations off
/// the main actor.
@MainActor
@Observable
final class AppModel {
    private(set) var entries: [InstanceEntry] = []
    private(set) var workspaces: [Workspace] = []
    /// The instance whose app is frontmost — shown in the menu bar.
    private(set) var frontmost: InstanceEntry?
    var selection: String?
    var errorMessage: String?
    /// Presents the New Instance flow (optionally preselecting an app).
    var creating: CreateIntent?
    /// Presents the New Workspace sheet.
    var makingWorkspace = false
    private(set) var busy: Set<String> = []
    private(set) var storage: [String: StorageReport] = [:]
    private(set) var isolation: [String: IsolationResult] = [:]
    private(set) var catalog: [CatalogApp] = []
    private(set) var catalogState: LoadState = .idle
    /// Instances whose shortcut another app already owns.
    private(set) var unavailableShortcuts: Set<String> = []
    /// While a shortcut is being recorded, instance shortcuts stand down so
    /// pressing one records it instead of firing it.
    var recordingShortcut = false
    /// Own-identity copies that quit right after opening this session.
    private(set) var quickExits: Set<String> = []
    /// Something worth telling after an action (not an error).
    var notice: Notice?

    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        /// Files to show in Finder, if any.
        var reveal: [URL] = []
    }

    enum LoadState { case idle, loading, loaded }

    struct CreateIntent: Identifiable {
        let id = UUID()
        var app: URL?
    }

    enum IsolationResult {
        case checking
        case report(IsolationReport)
        case failed(String)
    }

    /// Instances whose automatic repair failed this session (not retried).
    private(set) var maintenanceFailures: Set<String> = []
    @ObservationIgnored private var maintaining = false

    @ObservationIgnored private var healthyCopies: Set<String> = []
    /// Running processes already checked automatically (one check per launch).
    @ObservationIgnored private var autoVerified: Set<pid_t> = []
    /// Instances whose latest check found them writing to the original's data.
    private(set) var leaking: Set<String> = []
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        observeWorkspace()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var selectedEntry: InstanceEntry? {
        selection.flatMap { id in entries.first { $0.id == id } }
    }

    /// Instances grouped under the app they duplicate, apps alphabetical.
    var groups: [(app: String, entries: [InstanceEntry])] {
        Dictionary(grouping: entries, by: \.targetName)
            .map { (app: $0.key, entries: $0.value) }
            .sorted { $0.app.localizedStandardCompare($1.app) == .orderedAscending }
    }

    // MARK: - Registry

    func refresh() {
        let fresh = InstanceStore.loadAll().map { InstanceEntry(manifest: $0, status: InstanceStatus.check($0)) }
        if fresh != entries {
            entries = fresh
        }
        let freshWorkspaces = WorkspaceStore.load()
        if freshWorkspaces != workspaces {
            workspaces = freshWorkspaces
        }
        noteHealthyCopies()
        autoVerifyRunningInstances()
        if let selection, !entries.contains(where: { $0.id == selection }), selectedWorkspace == nil {
            self.selection = entries.first?.id
        }
        updateFrontmost()
    }

    // MARK: - Workspaces

    static let workspaceTagPrefix = "workspace:"

    static func tag(for workspace: Workspace) -> String {
        workspaceTagPrefix + workspace.id.uuidString
    }

    var selectedWorkspace: Workspace? {
        guard let selection, selection.hasPrefix(Self.workspaceTagPrefix) else { return nil }
        let id = selection.dropFirst(Self.workspaceTagPrefix.count)
        return workspaces.first { $0.id.uuidString == id }
    }

    /// The instances in a workspace, in its order.
    func members(of workspace: Workspace) -> [InstanceEntry] {
        let bySlug = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return workspace.members.compactMap { bySlug[$0] }
    }

    /// A new workspace (named "Workspace", "Workspace 2", …), selected.
    /// Change a workspace (applied to its stored state); returns an error
    /// message to show in place.
    @discardableResult
    func changeWorkspace(_ id: UUID, _ change: (inout Workspace) -> Void) -> String? {
        do {
            try WorkspaceStore.update(id: id, change)
            refresh()
            return nil
        } catch {
            return "\(error)"
        }
    }

    func deleteWorkspace(_ workspace: Workspace) {
        do {
            try WorkspaceStore.delete(id: workspace.id)
            if selectedWorkspace?.id == workspace.id {
                selection = entries.first?.id
            }
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func openWorkspace(_ workspace: Workspace) {
        let manifests = entries.map(\.manifest)
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                WorkspaceLauncher.open(workspace, manifests: manifests)
            }.value
            if let failure = outcome.failed.first {
                errorMessage = "Couldn't open \(failure.name): \(failure.reason)"
            }
            refresh()
        }
    }

    func quitWorkspace(_ workspace: Workspace) {
        _ = WorkspaceLauncher.quit(workspace, manifests: entries.map(\.manifest))
    }

    private func updateFrontmost() {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let front = pid.flatMap { pid in entries.first { $0.pid == pid } }
        if front?.id != frontmost?.id {
            frontmost = front
        }
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        // An instance quitting is the moment its upkeep can run — and the
        // moment to notice a copy that quit right after opening.
        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            let launched = app?.launchDate
            Task { @MainActor in
                self?.noteTermination(bundleID: bundleID, launched: launched)
                self?.maintainInstances()
            }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            Task { @MainActor in
                self?.updateFrontmost()
                // Sign-in link routing sends links to the copy used last.
                if let pid, LinkRouting.loadConfiguration().enabled {
                    LinkRouting.recordActivation(pid: pid)
                }
            }
        })
        // Apps re-register as their link scheme's handler while starting up;
        // take routed schemes back a few times after any launch.
        observers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { _ in
            Task {
                for delay in [3, 10, 30] as [UInt64] {
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    await LinkRouting.reassert()
                }
            }
        })
    }

    // MARK: - Copies that won't run

    private func noteTermination(bundleID: String?, launched: Date?) {
        guard let bundleID, let launched,
              let entry = entries.first(where: { $0.manifest.clone?.bundleIdentifier == bundleID })
        else { return }
        guard Date().timeIntervalSince(launched) < Compatibility.quickExitWindow else { return }
        quickExits.insert(entry.id)
        if let original = entry.manifest.knownTargetBundleID {
            let version = AppCloner.version(of: URL(fileURLWithPath: entry.manifest.targetApp))
            Compatibility.recordQuickExit(bundleID: original, version: version)
        }
    }

    /// A copy that's been running a while is fine: clear earlier trouble.
    private func noteHealthyCopies() {
        for entry in entries where entry.isClone && !healthyCopies.contains(entry.id) {
            guard let pid = entry.pid, let launched = NSRunningApplication(processIdentifier: pid)?.launchDate,
                  Date().timeIntervalSince(launched) > 30
            else { continue }
            healthyCopies.insert(entry.id)
            quickExits.remove(entry.id)
            if let original = entry.manifest.knownTargetBundleID {
                Compatibility.recordHealthyRun(bundleID: original)
            }
        }
    }

    func dismissQuickExit(_ entry: InstanceEntry) {
        quickExits.remove(entry.id)
    }

    // MARK: - Launching

    func activate(_ entry: InstanceEntry) {
        if let pid = entry.pid {
            InstanceLauncher.activate(pid: pid)
        } else {
            launch(entry)
        }
    }

    func launch(_ entry: InstanceEntry) {
        let manifest = entry.manifest
        perform(on: entry.id) { try InstanceLauncher.launch(manifest) }
    }

    func launchOriginal(_ entry: InstanceEntry) {
        let manifest = entry.manifest
        perform(on: entry.id) { try InstanceLauncher.launchOriginal(of: manifest) }
    }

    /// Open every instance marked "open when Parallex starts".
    func openAutostartInstances() {
        for entry in entries where entry.manifest.settings?.openAtLaunch == true && !entry.running {
            if entry.status.canLaunch {
                launch(entry)
            }
        }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func revealData(_ entry: InstanceEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.instanceDir(slug: entry.id)])
    }

    // MARK: - Changing instances

    func remove(_ entry: InstanceEntry, keepData: Bool) {
        let manifest = entry.manifest
        busy.insert(entry.id)
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try InstanceRemover.remove(manifest, keepData: keepData)
                }.value
                if !result.leftoverContainers.isEmpty {
                    notice = Notice(
                        title: "One more step for “\(manifest.name)”",
                        message: "macOS keeps an app's containers until you delete them yourself. "
                            + "Drag \(result.leftoverContainers.count == 1 ? "this folder" : "these \(result.leftoverContainers.count) folders") "
                            + "to the Trash in Finder to finish removing it.",
                        reveal: result.leftoverContainers.map { URL(fileURLWithPath: $0) }
                    )
                }
            } catch {
                errorMessage = "\(error)"
            }
            busy.remove(entry.id)
            refresh()
        }
    }

    func repair(_ entry: InstanceEntry, targetApp: URL? = nil) {
        let manifest = entry.manifest
        IconCache.invalidate(entry.manifest.wrapperPath)
        perform(on: entry.id, then: { [weak self] in self?.measureStorage() }) {
            _ = try InstanceCreator.update(manifest, InstanceUpdate(targetApp: targetApp))
        }
    }

    /// macOS won't give this copy a Library of its own: after confirming,
    /// turn Separate Library off so it opens as a plain copy that shares the
    /// original's data. What it kept in its own Library stays in its folder.
    func useAsPlainCopy(_ entry: InstanceEntry) {
        let alert = NSAlert()
        alert.messageText = "Use “\(entry.name)” as a plain copy?"
        alert.informativeText = "It keeps its own name, icon and Dock tile, but shares \(entry.targetName)'s settings, "
            + "data and sign-ins. What it saved on its own stays in its folder, so turning Separate Library back on "
            + "later brings it back."
        alert.addButton(withTitle: "Use as Plain Copy")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var changed = entry.manifest.effectiveSettings
        changed.separateLibrary = false
        let settings = changed
        let manifest = entry.manifest
        IconCache.invalidate(manifest.wrapperPath)
        perform(on: entry.id, then: { [weak self] in self?.measureStorage() }) {
            _ = try InstanceCreator.update(manifest, InstanceUpdate(settings: settings))
        }
    }

    /// Rebuild with changed settings; returns the rebuilt instance. Throws so
    /// the caller can show the error in context.
    @discardableResult
    func update(_ entry: InstanceEntry, _ change: InstanceUpdate) async throws -> InstanceManifest {
        let manifest = entry.manifest
        busy.insert(entry.id)
        defer {
            busy.remove(entry.id)
            IconCache.invalidate(manifest.wrapperPath)
            refresh()
            measureStorage()
        }
        let result = try await Task.detached(priority: .userInitiated) {
            try InstanceCreator.update(manifest, change)
        }.value
        IconCache.invalidate(result.manifest.wrapperPath)
        return result.manifest
    }

    /// Save settings that don't need a rebuild (launch preference, color);
    /// returns the saved instance, or nil after reporting an error.
    @discardableResult
    func saveSettings(_ settings: InstanceSettings, for entry: InstanceEntry) -> InstanceManifest? {
        do {
            let saved = try InstanceCreator.saveSettings(settings, for: entry.manifest)
            refresh()
            return saved
        } catch {
            errorMessage = "\(error)"
            return nil
        }
    }

    func create(_ request: CreateRequest, select: Bool = true) async throws -> CreateResult {
        let result = try await Task.detached(priority: .userInitiated) {
            try InstanceCreator.create(request)
        }.value
        refresh()
        if select {
            selection = result.manifest.slug
        }
        measureStorage()
        return result
    }

    /// A workspace in one go: instances you have, plus new copies of the
    /// chosen apps, each made the way the catalog recommends and in the
    /// workspace's color. The workspace comes first and each copy joins it
    /// as it's made, so nothing made is left outside it. `progress` hears
    /// which app is being made; apps that fail are reported and the rest
    /// carry on.
    func makeWorkspace(
        name: String,
        colorHex: String,
        existing: [String],
        newApps: [CatalogApp],
        progress: @escaping @MainActor (_ app: String, _ index: Int) -> Void
    ) async -> (workspace: Workspace?, failures: [String]) {
        let workspace: Workspace
        do {
            workspace = try WorkspaceStore.create(name: name, members: existing, colorHex: colorHex)
            refresh()
        } catch {
            return (nil, ["\(error)"])
        }
        var failures: [String] = []
        for (index, app) in newApps.enumerated() {
            progress(app.name, index)
            var request = CreateRequest(appReference: app.url.path)
            request.name = Self.freeName("\(app.name) \(name)", taken: Set(entries.map(\.name)))
            request.badgeColorHex = colorHex
            request.cloneApp = app.recommendsClone
            do {
                let result = try await create(request, select: false)
                try WorkspaceStore.update(id: workspace.id) { $0.members.append(result.manifest.slug) }
            } catch {
                failures.append("\(app.name): \(error)")
            }
        }
        refresh()
        selection = Self.tag(for: workspace)
        return (workspaces.first { $0.id == workspace.id } ?? workspace, failures)
    }

    /// What a shortcut or a menu bar icon does: open the instance if it's
    /// closed, bring it forward, or hide it when it's already in front.
    func bringForwardOrHide(_ entry: InstanceEntry) {
        if let pid = entry.pid, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            NSRunningApplication(processIdentifier: pid)?.hide()
        } else if entry.status.canLaunch || entry.running {
            activate(entry)
        }
    }

    /// Give instances a color (a workspace's). Instances without a badge
    /// change in place; badged ones are rebuilt to repaint their icon,
    /// except while they run (a copy can't be rebuilt underneath itself).
    func recolor(_ members: [InstanceEntry], to hex: String) {
        var waiting: [String] = []
        for entry in members where entry.manifest.colorHex.caseInsensitiveCompare(hex) != .orderedSame && !busy.contains(entry.id) {
            var settings = entry.manifest.effectiveSettings
            settings.badgeColorHex = hex
            if entry.manifest.effectiveSettings.requiresRebuild(toReach: settings) {
                if entry.running {
                    waiting.append(entry.name)
                    continue
                }
                Task {
                    do {
                        try await update(entry, InstanceUpdate(settings: settings))
                    } catch {
                        errorMessage = "Couldn't recolor \(entry.name): \(error)"
                    }
                }
            } else {
                saveSettings(settings, for: entry)
            }
        }
        if !waiting.isEmpty {
            errorMessage = "Quit \(waiting.joined(separator: ", ")) to give \(waiting.count == 1 ? "it" : "them") the color; "
                + "badged icons are repainted when the app isn't running."
        }
    }

    /// "Slack Work", or "Slack Work 2" when that's taken (by an instance,
    /// or by an app already in /Applications).
    static func freeName(_ base: String, taken: Set<String>) -> String {
        let lowered = Set(taken.map { $0.lowercased() })
        func free(_ name: String) -> Bool {
            !lowered.contains(name.lowercased())
                && !FileManager.default.fileExists(atPath: "/Applications/\(name).app")
        }
        guard !free(base) else { return base }
        var index = 2
        while !free("\(base) \(index)") {
            index += 1
        }
        return "\(base) \(index)"
    }

    /// Quit a running instance, bring it up to date, and open it again —
    /// for a copy that's behind its app.
    func restart(_ entry: InstanceEntry) {
        guard let pid = entry.pid, let app = NSRunningApplication(processIdentifier: pid) else {
            launch(entry)
            return
        }
        let id = entry.id
        Task {
            app.terminate()
            // Apps may ask to save first; give them a while.
            for _ in 0..<240 where !app.isTerminated {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard app.isTerminated else {
                errorMessage = "\(entry.name) didn't quit, so it wasn't restarted."
                return
            }
            // Automatic upkeep may already be rebuilding it after the quit.
            while busy.contains(id) {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            refresh()
            guard var current = entries.first(where: { $0.id == id }) else { return }
            if !current.status.problems.isEmpty, current.status.problems.allSatisfy(\.isMaintainable) {
                do {
                    _ = try await update(current, InstanceUpdate())
                } catch {
                    errorMessage = "Couldn't update \(entry.name): \(error)"
                }
                current = entries.first(where: { $0.id == id }) ?? current
            }
            // The new launch gets checked afresh.
            leaking.remove(id)
            isolation[id] = nil
            launch(current)
        }
    }

    // MARK: - Export and import

    func chooseArchiveToImport() {
        let panel = NSOpenPanel()
        panel.title = "Import Instance"
        panel.allowedContentTypes = [UTType(filenameExtension: InstanceArchive.fileExtension) ?? .zip]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            importInstance(from: url)
        }
    }

    /// Import a `.parallex` file after saying what it is — a file someone
    /// sent can be opened by double-clicking.
    func importInstance(from file: URL) {
        Task {
            do {
                let preview = try await Task.detached(priority: .userInitiated) {
                    try InstanceArchive.preview(file)
                }.value
                NSApp.activate()
                let alert = NSAlert()
                alert.messageText = "Import “\(preview.name)”?"
                var detail = "An instance of \(preview.appName), with its settings and data. It's added under a name that's free on this Mac."
                if !preview.extraArguments.isEmpty || !preview.extraEnvironment.isEmpty {
                    detail += "\n\nThe file also sets extra launch arguments or environment. They aren't imported — add them later in Advanced if you trust where the file came from."
                }
                alert.informativeText = detail
                alert.addButton(withTitle: "Import")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                let result = try await Task.detached(priority: .userInitiated) {
                    try InstanceArchive.import(from: file)
                }.value
                refresh()
                selection = result.manifest.slug
                measureStorage()
            } catch {
                errorMessage = "\(error)"
            }
        }
    }

    func export(_ entry: InstanceEntry) {
        let panel = NSSavePanel()
        panel.title = "Export “\(entry.name)”"
        panel.nameFieldStringValue = "\(entry.name).\(InstanceArchive.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: InstanceArchive.fileExtension) ?? .zip]
        panel.message = "Saves its settings and data in one file, for a backup or another Mac."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let manifest = entry.manifest
        perform(on: entry.id) { try InstanceArchive.export(manifest, to: url) }
    }

    /// Copy the original app's data into an own-identity copy.
    func copyOriginalData(into entry: InstanceEntry) {
        let manifest = entry.manifest
        perform(on: entry.id, then: { [weak self] in self?.measureStorage() }) {
            _ = try OriginalData.copy(into: manifest)
        }
    }

    func duplicate(_ entry: InstanceEntry, includeData: Bool) {
        let manifest = entry.manifest
        busy.insert(entry.id)
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try InstanceCreator.duplicate(manifest, includeData: includeData)
                }.value
                refresh()
                selection = result.manifest.slug
                measureStorage()
            } catch {
                errorMessage = "\(error)"
            }
            busy.remove(entry.id)
        }
    }

    // MARK: - Maintenance

    /// Rebuild instances that only need routine upkeep — built by an older
    /// Parallex, pointing at a moved app, or a copy older than its app —
    /// while they aren't running. Runs at launch and whenever an app quits.
    func maintainInstances() {
        guard UserDefaults.standard.object(forKey: PreferenceKey.autoMaintain) as? Bool ?? true,
              !maintaining
        else { return }
        let due = entries.filter { entry in
            !entry.running && !entry.status.problems.isEmpty
                && entry.status.problems.allSatisfy(\.isMaintainable)
                && !maintenanceFailures.contains(entry.id) && !busy.contains(entry.id)
        }
        guard !due.isEmpty else { return }
        maintaining = true
        Task {
            for entry in due {
                // Something else (a restart, an edit) may have taken it on
                // since the list was made.
                if busy.contains(entry.id) || Running.isRunning(entry.manifest) {
                    continue
                }
                let manifest = entry.manifest
                busy.insert(entry.id)
                do {
                    _ = try await Task.detached(priority: .utility) {
                        try InstanceCreator.update(manifest)
                    }.value
                    IconCache.invalidate(manifest.wrapperPath)
                } catch {
                    maintenanceFailures.insert(entry.id)
                }
                busy.remove(entry.id)
            }
            maintaining = false
            refresh()
        }
    }

    // MARK: - Verification

    func verifyIsolation(_ entry: InstanceEntry) {
        runIsolationCheck(entry, priority: .userInitiated)
    }

    private func runIsolationCheck(_ entry: InstanceEntry, priority: TaskPriority) {
        let manifest = entry.manifest
        let id = entry.id
        isolation[id] = .checking
        Task {
            let result: IsolationResult
            do {
                let report = try await Task.detached(priority: priority) {
                    try IsolationCheck.run(manifest)
                }.value
                result = .report(report)
                if report.isClean {
                    leaking.remove(id)
                } else {
                    leaking.insert(id)
                }
            } catch {
                result = .failed("\(error)")
            }
            isolation[id] = result
        }
    }

    /// Once an instance has been running ~45 s (long enough to open its
    /// data), check its isolation in the background — once per launch.
    private func autoVerifyRunningInstances() {
        guard UserDefaults.standard.object(forKey: PreferenceKey.autoVerify) as? Bool ?? true else { return }
        for entry in entries {
            guard let pid = entry.pid, !autoVerified.contains(pid),
                  let launched = NSRunningApplication(processIdentifier: pid)?.launchDate,
                  Date().timeIntervalSince(launched) > 45
            else { continue }
            autoVerified.insert(pid)
            runIsolationCheck(entry, priority: .utility)
        }
    }

    // MARK: - Storage

    func measureStorage() {
        let manifests = entries.map(\.manifest)
        Task {
            let reports = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: manifests.map { ($0.slug, InstanceStorage.report(for: $0)) })
            }.value
            storage = reports
        }
    }

    enum Reclaim { case caches, unused }

    func reclaim(_ kind: Reclaim, of entry: InstanceEntry) {
        guard let report = storage[entry.id] else { return }
        let items = (kind == .caches ? report.caches : report.unused).map(\.url)
        let manifest = entry.manifest
        perform(on: entry.id, then: { [weak self] in self?.measureStorage() }) {
            try InstanceStorage.trash(items, of: manifest)
        }
    }

    // MARK: - Catalog

    func loadCatalog() {
        guard catalogState == .idle else { return }
        catalogState = .loading
        Task {
            let apps = await Task.detached(priority: .userInitiated) { AppCatalog.scan() }.value
            catalog = apps
            catalogState = .loaded
        }
    }

    func probe(_ url: URL) async throws -> AppProbe {
        try await Task.detached(priority: .userInitiated) {
            try InstanceCreator.probe(appAt: url)
        }.value
    }

    // MARK: - Shortcuts

    func setUnavailableShortcuts(_ slugs: Set<String>) {
        if slugs != unavailableShortcuts {
            unavailableShortcuts = slugs
        }
    }

    /// Why `shortcut` can't be used for the instance `slug` (or the
    /// workspace with that id), if it can't.
    func shortcutConflict(_ shortcut: KeyShortcut, for slug: String) -> String? {
        if !shortcut.isValidGlobal {
            return "Include ⌃ or ⌥, so it doesn't take over typing or shortcuts like ⌘C."
        }
        if shortcut.sameKeys(as: Self.switcherShortcut),
           UserDefaults.standard.bool(forKey: PreferenceKey.switcherHotKey) {
            return "\(shortcut.displayString) opens the switcher."
        }
        if let owner = ShortcutOwners.owner(
            of: shortcut, except: slug, manifests: entries.map(\.manifest), workspaces: workspaces
        ) {
            return "\(shortcut.displayString) already opens \(owner)."
        }
        return nil
    }

    static let switcherShortcut = KeyShortcut(keyCode: 0x31, modifiers: [.control, .option], key: "Space")

    // MARK: - Helpers

    /// Run a blocking core operation off the main actor, surfacing errors.
    private func perform(
        on id: String,
        then completion: (@MainActor () -> Void)? = nil,
        _ body: @escaping @Sendable () throws -> Void
    ) {
        busy.insert(id)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try body() }.value
            } catch {
                errorMessage = "\(error)"
            }
            busy.remove(id)
            refresh()
            completion?()
        }
    }
}
