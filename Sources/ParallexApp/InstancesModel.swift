import AppKit
import Foundation
import ParallexCore

/// Observable source of truth for the UI. Reads the instance registry, tracks
/// which instances are running, and fronts the (blocking) core operations as
/// async calls that run off the main actor.
@MainActor
final class InstancesModel: ObservableObject {
    struct Entry: Identifiable {
        let manifest: InstanceManifest
        let running: Bool
        let wrapperExists: Bool
        let targetExists: Bool

        var id: String { manifest.slug }

        var targetName: String {
            URL(fileURLWithPath: manifest.targetApp).deletingPathExtension().lastPathComponent
        }

        var problem: String? {
            if !wrapperExists { return "wrapper missing" }
            if !targetExists { return "target app missing" }
            return nil
        }
    }

    @Published private(set) var entries: [Entry] = []
    @Published var errorMessage: String?

    private var refreshTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        refresh()

        // Launch/terminate events keep the running dots honest; the timer
        // catches registry changes made by the CLI while the app is open.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let fm = FileManager.default
        entries = InstanceStore.loadAll().map { manifest in
            Entry(
                manifest: manifest,
                running: Running.isRunning(instanceSlug: manifest.slug, targetBinary: manifest.targetBinary),
                wrapperExists: fm.fileExists(atPath: manifest.wrapperPath),
                targetExists: fm.fileExists(atPath: manifest.targetApp)
            )
        }
    }

    // MARK: - Actions

    func launch(_ entry: Entry) {
        // Already running → bring it to the front instead of spawning a copy
        // that would lose the app's single-instance race and look like a dud.
        if let pid = Running.processID(
            instanceSlug: entry.manifest.slug,
            targetBinary: entry.manifest.targetBinary
        ),
           let app = NSRunningApplication(processIdentifier: pid) {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
            return
        }
        launchWrapper(at: entry.manifest.wrapperPath)
    }

    /// Launch the *original* app while instances run. A plain open/Dock click
    /// can get swallowed: a running instance re-registers under the target's
    /// identity after exec, so Launch Services "activates" it instead of
    /// starting the original. Forcing a new application instance bypasses that.
    func launchOriginal(_ entry: Entry) {
        let url = URL(fileURLWithPath: entry.manifest.targetApp)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    self?.errorMessage = error.localizedDescription
                }
                self?.refresh()
            }
        }
    }

    func launchWrapper(at path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    self?.errorMessage = error.localizedDescription
                }
                self?.refresh()
            }
        }
    }

    func revealWrapper(_ entry: Entry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.manifest.wrapperPath)])
    }

    func revealData(_ entry: Entry) {
        let dir = Paths.instanceDir(slug: entry.manifest.slug)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    func remove(_ entry: Entry, keepData: Bool) {
        let manifest = entry.manifest
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try InstanceRemover.remove(manifest, keepData: keepData)
                }.value
            } catch {
                errorMessage = "\(error)"
            }
            refresh()
        }
    }

    /// Re-assemble the wrapper from the manifest — e.g. if something damaged
    /// it. Instance data is kept; user choices come from the manifest.
    func rebuild(_ entry: Entry) {
        let manifest = entry.manifest
        Task {
            do {
                var request = CreateRequest(
                    appReference: manifest.targetApp,
                    name: manifest.name,
                    outputDirectory: URL(fileURLWithPath: manifest.wrapperPath).deletingLastPathComponent(),
                    force: true
                )
                request.mode = RequestedMode(rawValue: manifest.mode.rawValue) ?? .auto
                _ = try await Task.detached(priority: .userInitiated) { [request] in
                    try InstanceCreator.create(request)
                }.value
            } catch {
                errorMessage = "\(error)"
            }
            refresh()
        }
    }

    func probeApp(at url: URL) async throws -> AppProbe {
        try await Task.detached(priority: .userInitiated) {
            try InstanceCreator.probe(appAt: url)
        }.value
    }

    func create(_ request: CreateRequest) async throws -> CreateResult {
        let result = try await Task.detached(priority: .userInitiated) {
            try InstanceCreator.create(request)
        }.value
        refresh()
        return result
    }
}
