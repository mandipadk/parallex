import AppKit
import Foundation
import ParallexKit

/// Everything the UIs show about an instance's health, computed in one place
/// so the CLI and the app agree.
public struct InstanceStatus: Sendable {
    public enum Problem: Sendable, Equatable {
        /// The wrapper .app is gone (deleted, moved). Repair rebuilds it.
        case wrapperMissing
        /// The original app is gone and can't be found by bundle ID.
        case targetMissing
        /// The original app moved; the wrapper finds it at launch, and a
        /// repair records the new location.
        case targetMoved(to: String)
        /// The wrapper was built by an older Parallex; a repair picks up
        /// launcher and recipe improvements. Everything still works.
        case wrapperOutdated(builtWith: String)
        /// Clone mode: the original app updated since the copy was made.
        case cloneOutdated(copyOf: String, original: String)

        public var isBlocking: Bool {
            switch self {
            case .wrapperMissing, .targetMissing: true
            case .targetMoved, .wrapperOutdated, .cloneOutdated: false
            }
        }

        public var summary: String {
            switch self {
            case .wrapperMissing: "wrapper missing"
            case .targetMissing: "original app missing"
            case .targetMoved(let path): "original app moved to \(Paths.abbreviate(path))"
            case .wrapperOutdated(let version): "built with Parallex \(version) — repair to update"
            case .cloneOutdated(let copy, let original):
                "copy is of \(copy); the app is now \(original) — repair to refresh the copy"
            }
        }
    }

    public let pid: pid_t?
    public let problems: [Problem]

    public var running: Bool { pid != nil }
    public var canLaunch: Bool { !problems.contains { $0.isBlocking } }

    public static func check(_ manifest: InstanceManifest) -> InstanceStatus {
        let fm = FileManager.default
        var problems: [Problem] = []
        let wrapper = URL(fileURLWithPath: manifest.wrapperPath)
        if !fm.fileExists(atPath: wrapper.path) {
            problems.append(.wrapperMissing)
        } else if let version = wrapperVersion(wrapper),
                  compareVersions(version, ParallexConfig.version) == .orderedAscending {
            problems.append(.wrapperOutdated(builtWith: version))
        }
        if let clone = manifest.clone, fm.fileExists(atPath: manifest.targetApp) {
            let current = AppCloner.version(of: URL(fileURLWithPath: manifest.targetApp))
            if current != clone.sourceVersion {
                problems.append(.cloneOutdated(copyOf: clone.sourceVersion, original: current))
            }
        }
        if !fm.fileExists(atPath: manifest.targetApp) {
            if let bundleID = manifest.knownTargetBundleID, let moved = AppResolver.locate(bundleID: bundleID) {
                problems.append(.targetMoved(to: moved.path))
            } else {
                problems.append(.targetMissing)
            }
        }
        return InstanceStatus(
            pid: Running.processID(of: manifest),
            problems: problems
        )
    }

    static func wrapperVersion(_ wrapper: URL) -> String? {
        guard let data = try? Data(contentsOf: wrapper.appendingPathComponent("Contents/Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else {
            return nil
        }
        return plist["CFBundleShortVersionString"] as? String
    }

    /// Numeric dotted-version comparison ("0.10.0" > "0.9.1").
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r {
                return l < r ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }
}

/// Launching instances and their originals — shared by the CLI and the app.
public enum InstanceLauncher {
    /// Launch an instance, or bring it to the front if it's already running
    /// (a second launch would lose the app's single-instance race).
    public static func launch(_ manifest: InstanceManifest) throws {
        if let pid = Running.processID(of: manifest) {
            activate(pid: pid)
            return
        }
        guard FileManager.default.fileExists(atPath: manifest.wrapperPath) else {
            throw ParallexError(
                "The wrapper for '\(manifest.name)' is missing at \(manifest.wrapperPath). "
                + "Repair it with: parallex repair \"\(manifest.name)\""
            )
        }
        try Shell.run("/usr/bin/open", [manifest.wrapperPath], environment: cleanEnvironment())
    }

    /// This process's environment minus any instance's isolation variables
    /// (`open` passes the caller's environment to the app it launches).
    public static func cleanEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let root = Paths.instancesRoot.path
        for (key, value) in environment where InheritedIsolation.matches(key: key, value: value, instancesRoot: root) {
            if key == "HOME" {
                environment[key] = FileManager.default.homeDirectoryForCurrentUser.path
            } else {
                environment[key] = nil
            }
        }
        return environment
    }

    /// Launch the *original* app while instances run. A running instance
    /// carries the target's Launch Services identity (the exec'd app checks
    /// in under its own bundle ID), so a plain open or Dock click would just
    /// activate the instance. `open -n` forces a genuinely new process.
    public static func launchOriginal(of manifest: InstanceManifest) throws {
        let target = try InstanceCreator.locateTarget(of: manifest)
        try Shell.run("/usr/bin/open", ["-n", target.path], environment: cleanEnvironment())
    }

    public static func activate(pid: pid_t) {
        onMainThread {
            _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
        }
    }
}
