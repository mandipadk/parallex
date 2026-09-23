import AppKit
import Foundation
import ParallexCore

/// Observable source of truth for the UI. Reads the instance registry, tracks
/// which instances are running and which one is in front, and fronts the
/// (blocking) core operations as async calls that run off the main actor.
@MainActor
final class InstancesModel: ObservableObject {
    struct Entry: Identifiable {
        let manifest: InstanceManifest
        let status: InstanceStatus

        var id: String { manifest.slug }
        var running: Bool { status.running }
        var pid: pid_t? { status.pid }
        var wrapperExists: Bool { !status.problems.contains(.wrapperMissing) }
        var color: NSColor { NSColor(hex: manifest.colorHex) ?? .systemIndigo }

        var targetName: String {
            URL(fileURLWithPath: manifest.targetApp).deletingPathExtension().lastPathComponent
        }

        var needsRepair: Bool {
            status.problems.contains {
                if case .targetMissing = $0 { return false }
                return true
            }
        }
    }

    @Published private(set) var entries: [Entry] = []
    /// The instance whose app is frontmost, if any — shown in the menu bar.
    @Published private(set) var frontmost: Entry?
    @Published var errorMessage: String?
    /// Slugs with an operation in flight (rebuild, repair, …).
    @Published private(set) var busy: Set<String> = []
    /// Disk usage per instance slug; measured in the background on demand.
    @Published private(set) var storage: [String: StorageReport] = [:]

    private var refreshTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        refresh()

        // Launch/terminate/activate events keep running state and the
        // front-instance indicator honest; the timer catches registry changes
        // made by the CLI while the app is open.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateFrontmost() }
        })
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        entries = InstanceStore.loadAll().map { Entry(manifest: $0, status: InstanceStatus.check($0)) }
        updateFrontmost()
    }

    private func updateFrontmost() {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        frontmost = pid.flatMap { pid in entries.first { $0.pid == pid } }
    }

    // MARK: - Launching

    func launch(_ entry: Entry) {
        let manifest = entry.manifest
        run(entry, refreshAfter: true) {
            try InstanceLauncher.launch(manifest)
        }
    }

    /// Launch the *original* app while instances run (see
    /// `InstanceLauncher.launchOriginal` for why this needs care).
    func launchOriginal(_ entry: Entry) {
        let manifest = entry.manifest
        run(entry, refreshAfter: true) {
            try InstanceLauncher.launchOriginal(of: manifest)
        }
    }

    func activate(_ entry: Entry) {
        if let pid = entry.pid {
            InstanceLauncher.activate(pid: pid)
        } else {
            launch(entry)
        }
    }

    func revealWrapper(_ entry: Entry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.manifest.wrapperPath)])
    }

    func revealData(_ entry: Entry) {
        let dir = Paths.instanceDir(slug: entry.manifest.slug)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    // MARK: - Changing instances

    func remove(_ entry: Entry, keepData: Bool) {
        let manifest = entry.manifest
        run(entry, refreshAfter: true) {
            _ = try InstanceRemover.remove(manifest, keepData: keepData)
        }
    }

    /// Rebuild the wrapper from the saved settings — fixes a missing or
    /// outdated wrapper, and records a moved original app.
    func repair(_ entry: Entry, targetApp: URL? = nil) {
        let manifest = entry.manifest
        run(entry, refreshAfter: true, then: { [weak self] in self?.measureStorage() }) {
            _ = try InstanceCreator.update(manifest, InstanceUpdate(targetApp: targetApp))
        }
    }

    func update(_ entry: Entry, _ change: InstanceUpdate) async throws {
        let manifest = entry.manifest
        busy.insert(entry.id)
        defer {
            busy.remove(entry.id)
            refresh()
            measureStorage()
        }
        _ = try await Task.detached(priority: .userInitiated) {
            try InstanceCreator.update(manifest, change)
        }.value
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

    func reclaim(_ kind: Reclaim, of entry: Entry) {
        guard let report = storage[entry.id] else { return }
        let items = (kind == .caches ? report.caches : report.unused).map(\.url)
        let manifest = entry.manifest
        run(entry, refreshAfter: true, then: { [weak self] in self?.measureStorage() }) {
            try InstanceStorage.trash(items, of: manifest)
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

    /// Run a blocking core operation off the main actor, surfacing errors.
    private func run(
        _ entry: Entry,
        refreshAfter: Bool,
        then completion: (@MainActor () -> Void)? = nil,
        _ body: @escaping @Sendable () throws -> Void
    ) {
        busy.insert(entry.id)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try body() }.value
            } catch {
                errorMessage = "\(error)"
            }
            busy.remove(entry.id)
            if refreshAfter {
                refresh()
            }
            completion?()
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("#") {
            cleaned.removeFirst()
        }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            return nil
        }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? .systemIndigo
        return String(
            format: "#%02X%02X%02X",
            Int(round(color.redComponent * 255)),
            Int(round(color.greenComponent * 255)),
            Int(round(color.blueComponent * 255))
        )
    }
}
