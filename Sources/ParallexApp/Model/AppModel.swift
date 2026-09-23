import AppKit
import Observation
import ParallexCore
import SwiftUI

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
            if case .targetMissing = $0 { return false }
            return true
        }
    }

    var runState: RunState {
        if let blocking = status.problems.first(where: \.isBlocking) {
            return .broken(blocking == .wrapperMissing ? "Needs repair" : "App missing")
        }
        if running {
            return .running
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
    /// The instance whose app is frontmost — shown in the menu bar.
    private(set) var frontmost: InstanceEntry?
    var selection: String?
    var errorMessage: String?
    /// Presents the New Instance flow (optionally preselecting an app).
    var creating: CreateIntent?
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
        if let selection, !entries.contains(where: { $0.id == selection }) {
            self.selection = entries.first?.id
        }
        updateFrontmost()
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
        // An instance quitting is the moment its upkeep can run.
        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.maintainInstances() }
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
        perform(on: entry.id) { _ = try InstanceRemover.remove(manifest, keepData: keepData) }
    }

    func repair(_ entry: InstanceEntry, targetApp: URL? = nil) {
        let manifest = entry.manifest
        IconCache.invalidate(entry.manifest.wrapperPath)
        perform(on: entry.id, then: { [weak self] in self?.measureStorage() }) {
            _ = try InstanceCreator.update(manifest, InstanceUpdate(targetApp: targetApp))
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

    func create(_ request: CreateRequest) async throws -> CreateResult {
        let result = try await Task.detached(priority: .userInitiated) {
            try InstanceCreator.create(request)
        }.value
        refresh()
        selection = result.manifest.slug
        measureStorage()
        return result
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
            launch(current)
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
        let manifest = entry.manifest
        isolation[entry.id] = .checking
        Task {
            let result: IsolationResult
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try IsolationCheck.run(manifest)
                }.value
                result = .report(report)
            } catch {
                result = .failed("\(error)")
            }
            isolation[entry.id] = result
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

    /// Why `shortcut` can't be used for the instance `slug`, if it can't.
    func shortcutConflict(_ shortcut: KeyShortcut, for slug: String) -> String? {
        if !shortcut.isValidGlobal {
            return "Include ⌃ or ⌥, so it doesn't take over typing or shortcuts like ⌘C."
        }
        if shortcut.sameKeys(as: Self.switcherShortcut),
           UserDefaults.standard.bool(forKey: PreferenceKey.switcherHotKey) {
            return "\(shortcut.displayString) opens the switcher."
        }
        if let owner = entries.first(where: { $0.id != slug && $0.manifest.settings?.shortcut?.sameKeys(as: shortcut) == true }) {
            return "\(shortcut.displayString) already opens “\(owner.name)”."
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
