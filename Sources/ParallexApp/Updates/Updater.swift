import AppKit
import Observation
import ParallexCore
import ParallexKit

/// Keeps Parallex itself up to date: checks GitHub Releases once a day (and
/// on request), shows what's new, and installs a verified update in place.
///
/// An update is installed only if its archive carries a valid signature
/// from the Parallex release key and unpacks to a Parallex app with a newer
/// version. The running app is replaced atomically and relaunched.
@MainActor
@Observable
final class Updater {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(ReleaseInfo, progress: Double)
        case installing(ReleaseInfo)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var lastChecked: Date?
    /// Presents the update window.
    var showWindow: (() -> Void)?
    var notifier: Notifier?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var download: Task<Void, Never>?
    @ObservationIgnored private var workspace: URL?

    static let checkInterval: TimeInterval = 24 * 60 * 60

    enum Keys {
        static let automatic = "checkForUpdatesAutomatically"
        static let lastChecked = "lastUpdateCheck"
        static let skipped = "skippedUpdateVersion"
        static let activity = "updateCheckActivity"
    }

    init() {
        lastChecked = UserDefaults.standard.object(forKey: Keys.lastChecked) as? Date
    }

    var automaticChecks: Bool {
        get {
            access(keyPath: \.automaticChecks)
            return UserDefaults.standard.object(forKey: Keys.automatic) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.automaticChecks) {
                UserDefaults.standard.set(newValue, forKey: Keys.automatic)
            }
        }
    }

    /// The release waiting to be installed, if any.
    var available: ReleaseInfo? {
        switch phase {
        case .available(let release), .downloading(let release, _), .installing(let release): release
        default: nil
        }
    }

    /// Whether this copy of Parallex can replace itself (a real app bundle
    /// in a folder the user can write to — not a development build).
    var canInstallInPlace: Bool {
        let bundle = Bundle.main.bundleURL
        return bundle.pathExtension == "app"
            && !bundle.path.contains("/.build/")
            && FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
    }

    // MARK: - Checking

    /// Check now if automatic checks are on and the last one is a day old;
    /// then keep checking while Parallex runs.
    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        // Give launch a moment before touching the network.
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            checkIfDue()
        }
    }

    private func checkIfDue() {
        guard automaticChecks else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.checkInterval {
            return
        }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        switch phase {
        case .checking, .downloading, .installing: return
        default: break
        }
        if userInitiated {
            phase = .checking
        }
        // What this check is the first of (today, this week…), for the
        // count on Parallex's server; kept once the server has it.
        let stored = UserDefaults.standard.data(forKey: Keys.activity)
            .flatMap { try? JSONDecoder().decode(CheckActivity.self, from: $0) } ?? CheckActivity()
        let activity = stored.periods(at: Date(), checkedBefore: lastChecked != nil)
        Task {
            do {
                let next = activity.next
                let (release, _) = try await UpdateFeed.fetchLatest(activity: activity.periods) {
                    if let data = try? JSONEncoder().encode(next) {
                        UserDefaults.standard.set(data, forKey: Keys.activity)
                    }
                }
                record(checkedAt: Date())
                let skipped = UserDefaults.standard.string(forKey: Keys.skipped)
                if UpdateFeed.isNewer(release.version), userInitiated || release.version != skipped {
                    phase = .available(release)
                    if userInitiated {
                        showWindow?()
                    } else {
                        notifier?.notifyUpdate(version: release.version)
                    }
                } else if userInitiated || phase == .checking {
                    phase = .upToDate
                }
            } catch {
                if userInitiated {
                    phase = .failed(Self.describe(error))
                }
            }
        }
    }

    private func record(checkedAt date: Date) {
        lastChecked = date
        UserDefaults.standard.set(date, forKey: Keys.lastChecked)
    }

    func skip(_ release: ReleaseInfo) {
        UserDefaults.standard.set(release.version, forKey: Keys.skipped)
        phase = .idle
    }

    func dismiss() {
        if case .failed = phase {
            phase = .idle
        } else if case .upToDate = phase {
            phase = .idle
        }
    }

    // MARK: - Installing

    func install(_ release: ReleaseInfo) {
        guard canInstallInPlace else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        download?.cancel()
        phase = .downloading(release, progress: 0)
        download = Task {
            do {
                let app = try await fetchAndVerify(release)
                phase = .installing(release)
                try replaceRunningApp(with: app)
                relaunch()
            } catch let error where Self.isCancellation(error) {
                cleanUp()
                phase = .available(release)
            } catch {
                cleanUp()
                phase = .failed(Self.describe(error))
            }
        }
    }

    func cancelDownload() {
        download?.cancel()
    }

    /// Download the archive and its signature, verify, unpack, and check the
    /// app inside. Returns the unpacked Parallex.app.
    private func fetchAndVerify(_ release: ReleaseInfo) async throws -> URL {
        // Stage on the same volume as the installed app, so the final swap
        // is a rename.
        let workspace = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: Bundle.main.bundleURL, create: true
        )
        self.workspace = workspace

        let (signatureData, _) = try await URLSession.shared.data(from: release.signatureURL)
        let archive = try await downloadArchive(release, into: workspace)
        try Task.checkCancellation()

        let bundleID = Bundle.main.bundleIdentifier
        // Verifying and unpacking take a moment; keep them off the main actor.
        return try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: archive, options: .mappedIfSafe)
            guard UpdateSignature.verify(data, signature: String(decoding: signatureData, as: UTF8.self)) else {
                throw ParallexError("The downloaded update isn't signed by Parallex, so it wasn't installed.")
            }
            let unpacked = workspace.appendingPathComponent("unpacked", isDirectory: true)
            try Shell.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
            let app = unpacked.appendingPathComponent("Parallex.app", isDirectory: true)
            guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                  plist["CFBundleIdentifier"] as? String == bundleID,
                  let version = plist["CFBundleShortVersionString"] as? String,
                  version == release.version, UpdateFeed.isNewer(version)
            else {
                throw ParallexError("The update's contents didn't match release \(release.version), so it wasn't installed.")
            }
            return app
        }.value
    }

    /// Remove the download staging area after a failure or a cancel (a
    /// successful install relaunches, and macOS clears these folders).
    private func cleanUp() {
        if let workspace {
            try? FileManager.default.removeItem(at: workspace)
        }
        workspace = nil
    }

    private func downloadArchive(_ release: ReleaseInfo, into directory: URL) async throws -> URL {
        let delegate = DownloadProgress { [weak self] progress in
            Task { @MainActor in
                guard let self, case .downloading = self.phase else { return }
                self.phase = .downloading(release, progress: progress)
            }
        }
        let (temporary, response) = try await URLSession.shared.download(from: release.archiveURL, delegate: delegate)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ParallexError("The download failed (\(http.statusCode)).")
        }
        let destination = directory.appendingPathComponent(UpdateFeed.archiveName(for: release.version))
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// Swap the new app into place. `replaceItemAt` exchanges the two
    /// bundles atomically, so an interrupted update leaves the old app.
    private func replaceRunningApp(with app: URL) throws {
        let current = Bundle.main.bundleURL
        _ = try FileManager.default.replaceItemAt(current, withItemAt: app, backupItemName: nil, options: [])
        // Downloads made by URLSession aren't quarantined, but be sure.
        _ = try? Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", current.path])
    }

    /// Relaunch once this process has exited.
    private func relaunch() {
        let path = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, path]
        try? process.run()
        NSApp.terminate(nil)
    }

    #if DEBUG
    /// Visual review only: show the window in a given state.
    func debugShow(_ phase: String) {
        let release = ReleaseInfo(
            version: "0.9.0",
            notes: """
            ## Deep isolation for native apps
            - Own-identity copies of native apps now keep **everything** in their own Library — Application Support, caches and web storage.
            - Existing copies pick this up automatically the next time they're updated.

            ## Also new
            - Workspaces: open a set of instances together with one shortcut.
            - `parallex://open/<name>` opens an instance from anywhere.
            """,
            pageURL: URL(string: "https://github.com/mandipadk/parallex/releases")!,
            archiveURL: URL(string: "https://example.com/a.zip")!,
            archiveSize: 9_000_000,
            signatureURL: URL(string: "https://example.com/a.zip.sig")!,
            publishedAt: Date()
        )
        switch phase {
        case "downloading": self.phase = .downloading(release, progress: 0.42)
        case "current": self.phase = .upToDate
        case "failed": self.phase = .failed("You're offline. Try again when you're connected.")
        default: self.phase = .available(release)
        }
    }
    #endif

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost: return "You're offline. Try again when you're connected."
            case .timedOut: return "The update server took too long to answer. Try again in a bit."
            default: return urlError.localizedDescription
            }
        }
        return "\(error)"
    }
}

/// Reports download progress (0…1) as bytes arrive.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private var lastReported = -1.0

    init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        if progress - lastReported >= 0.01 || progress >= 1 {
            lastReported = progress
            report(progress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
