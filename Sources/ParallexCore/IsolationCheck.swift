import Darwin
import Foundation

/// Verifies a running instance's isolation by looking at the files its
/// processes actually have open, instead of trusting the recipe.
///
/// Classification of each open file under the user's home:
/// - **isolated**: inside the instance directory.
/// - **leak**: in a location that belongs to the original app's data (its
///   Application Support folder, logs, preferences, `~/.<app>`, …).
/// - **shared by identity**: stores macOS keys by bundle ID (URL cache,
///   HTTP cookie storage, …). A running instance carries the original's
///   bundle ID, so these can't be separated.
/// - **shared by choice**: locations the instance's settings deliberately
///   share (home-mode symlinks, recipe options left off).
/// - **other**: anything else in the home folder (documents the user opened,
///   tool caches) — listed for context.
///
/// Limits: this is a snapshot of open files, so short writes between checks
/// can be missed, and preference writes go through `cfprefsd` (a system
/// daemon) rather than the app's own file handles.
public struct IsolationReport: Sendable {
    public enum Category: String, Sendable, CaseIterable, Codable {
        case isolated
        case leak
        case sharedByIdentity = "shared-by-identity"
        case sharedByChoice = "shared-by-choice"
        case other
    }

    public struct Finding: Sendable, Codable, Hashable {
        public let path: String
        public let category: Category
        /// Why a path landed in its category (e.g. which rule matched).
        public let reason: String
    }

    public let processCount: Int
    public let fileCount: Int
    public let findings: [Finding]

    public func findings(in category: Category) -> [Finding] {
        findings.filter { $0.category == category }
    }

    public var isClean: Bool { findings(in: .leak).isEmpty }
}

public enum IsolationCheck {
    public static func run(_ manifest: InstanceManifest) throws -> IsolationReport {
        guard let pid = Running.processID(of: manifest) else {
            throw ParallexError("“\(manifest.name)” isn't running — start it, use it for a moment, then check again.")
        }
        let instanceDir = Paths.instanceDir(slug: manifest.slug).path
        let pids = processTree(root: pid, alsoMatching: instanceDir + "/")
        var paths = Set<String>()
        for member in pids {
            paths.formUnion(openFiles(of: member))
        }
        let rules = Rules(manifest: manifest, home: FileManager.default.homeDirectoryForCurrentUser.path)
        let findings = paths.compactMap { rules.classify($0) }
            .sorted { ($0.category.rawValue, $0.path) < ($1.category.rawValue, $1.path) }
        return IsolationReport(processCount: pids.count, fileCount: paths.count, findings: findings)
    }

    // MARK: - Classification

    struct Rules {
        let home: String
        let instanceDir: String
        /// The instance's own app (a copy's resources aren't data).
        let appBundle: String
        let originalDataLocations: [(prefix: String, reason: String)]
        let identityLocations: [String]
        /// Recipe-declared folders the app can't be told to move.
        let appShared: [(prefix: String, reason: String)]
        let sharedByChoice: [(prefix: String, reason: String)]

        init(manifest: InstanceManifest, home: String) {
            self.home = home
            instanceDir = Paths.instanceDir(slug: manifest.slug).path
            appBundle = URL(fileURLWithPath: manifest.wrapperPath).resolvingSymlinksInPath().path

            let appName = URL(fileURLWithPath: manifest.targetApp).deletingPathExtension().lastPathComponent
            let bundleID = manifest.targetBundleID ?? Self.bundleID(ofApp: manifest.targetApp) ?? ""
            let library = home + "/Library"
            var names = Set([appName])
            if let productName = Self.bundleName(ofApp: manifest.targetApp) {
                names.insert(productName)
            }

            var original: [(String, String)] = []
            for folder in Presets.originalDataFolders(bundleID: bundleID, names: names.sorted()) {
                original.append(("\(library)/Application Support/\(folder)/", "the original's app data"))
            }
            for name in names {
                original.append(("\(library)/Logs/\(name)/", "the original's logs"))
            }
            let slug = Slug.make(appName)
            if !slug.isEmpty {
                original.append(("\(home)/.\(slug)/", "the original's ~/.\(slug) folder"))
            }
            if !bundleID.isEmpty {
                original.append(("\(library)/Preferences/\(bundleID).plist", "the original's preferences"))
                original.append(("\(library)/Saved Application State/\(bundleID).savedState/", "the original's window state"))
                original.append(("\(library)/Containers/\(bundleID)/", "the original's sandbox container"))
            }
            // Recipe-specific state the original keeps in the home folder.
            let recipeState: [String: [String]] = [
                "com.openai.codex": ["\(home)/.codex/"],
                "com.anthropic.claudefordesktop": ["\(home)/.claude/", "\(home)/.claude.json"],
            ]
            var choice: [(String, String)] = []
            if let recipe = manifest.recipe, let paths = recipeState[recipe.id] {
                let isolatesAll = recipe.id == "com.openai.codex"
                    || manifest.environment["CLAUDE_CONFIG_DIR"] != nil
                for path in paths {
                    if isolatesAll {
                        original.append((path, "state the recipe moves into the instance"))
                    } else {
                        choice.append((path, "shared on purpose (recipe option off)"))
                    }
                }
            }
            for item in manifest.homeSymlinks ?? [] {
                choice.append(("\(home)/\(item)", "shared into the instance home"))
            }
            func keyedByBundleID(_ id: String) -> [String] {
                [
                    "\(library)/Caches/\(id)/",
                    "\(library)/HTTPStorages/\(id)/",
                    "\(library)/HTTPStorages/\(id).binarycookies",
                    "\(library)/WebKit/\(id)/",
                    "\(library)/Cookies/\(id).binarycookies",
                ]
            }
            if manifest.redirectedHome != nil {
                // A copy with its own Library keeps even what macOS keys by
                // bundle ID in the instance, so finding it in the real
                // Library is a leak — and nothing is excused as unavoidable.
                let ids = [bundleID, manifest.clone?.bundleIdentifier ?? ""].filter { !$0.isEmpty }
                for location in ids.flatMap(keyedByBundleID) {
                    original.append((location, "belongs in the copy's own Library"))
                }
                identityLocations = []
                appShared = []
            } else {
                identityLocations = bundleID.isEmpty ? [] : keyedByBundleID(bundleID)
                appShared = (manifest.recipe?.unavoidablyShared ?? []).map { ("\(home)/\($0.path)", $0.reason) }
            }
            originalDataLocations = original
            sharedByChoice = choice
        }

        func classify(_ path: String) -> IsolationReport.Finding? {
            // Only the user's own files matter; system, app-bundle, and temp
            // files are expected to be shared.
            guard path.hasPrefix(home + "/"), !path.hasPrefix(appBundle + "/") else { return nil }
            if path.hasPrefix(instanceDir + "/") || path == instanceDir {
                return .init(path: path, category: .isolated, reason: "inside the instance directory")
            }
            if let match = sharedByChoice.first(where: { matches(path, $0.prefix) }) {
                return .init(path: path, category: .sharedByChoice, reason: match.reason)
            }
            if let match = appShared.first(where: { matches(path, $0.prefix) }) {
                return .init(path: path, category: .sharedByIdentity, reason: match.reason)
            }
            if let match = originalDataLocations.first(where: { matches(path, $0.prefix) }) {
                return .init(path: path, category: .leak, reason: match.reason)
            }
            if identityLocations.contains(where: { matches(path, $0) }) {
                return .init(
                    path: path, category: .sharedByIdentity,
                    reason: "macOS keys this by bundle ID, which the instance shares with the original"
                )
            }
            return .init(path: path, category: .other, reason: "outside the app's known data locations")
        }

        /// `prefix` ending in "/" is a folder (the path is it or inside it);
        /// otherwise it's a file or folder matched exactly or as a parent.
        private func matches(_ path: String, _ prefix: String) -> Bool {
            if prefix.hasSuffix("/") {
                return path.hasPrefix(prefix) || path + "/" == prefix
            }
            return path == prefix || path.hasPrefix(prefix + "/")
        }

        static func infoPlist(ofApp path: String) -> [String: Any]? {
            let url = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: url) else { return nil }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        }

        static func bundleID(ofApp path: String) -> String? {
            infoPlist(ofApp: path)?["CFBundleIdentifier"] as? String
        }

        static func bundleName(ofApp path: String) -> String? {
            infoPlist(ofApp: path)?["CFBundleName"] as? String
        }
    }

    // MARK: - Processes

    /// The instance's process plus its descendants, plus any process whose
    /// arguments point into the instance directory (helpers like crash
    /// handlers get reparented to launchd but keep the data-dir flag).
    static func processTree(root: pid_t, alsoMatching marker: String) -> [pid_t] {
        let all = allPIDs()
        var parents: [pid_t: pid_t] = [:]
        for pid in all {
            var info = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 {
                parents[pid] = pid_t(info.pbi_ppid)
            }
        }
        var members: Set<pid_t> = [root]
        var changed = true
        while changed {
            changed = false
            for (pid, parent) in parents where !members.contains(pid) && members.contains(parent) {
                members.insert(pid)
                changed = true
            }
        }
        for pid in all where !members.contains(pid) {
            if arguments(of: pid).contains(where: { $0.contains(marker) }) {
                members.insert(pid)
            }
        }
        return members.sorted()
    }

    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(count, 0)))).filter { $0 > 0 }
    }

    /// argv of another process via KERN_PROCARGS2 (readable for the user's
    /// own processes; the environment block is not, on current macOS).
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path and its padding.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    /// Paths of the regular files and directories a process has open.
    static func openFiles(of pid: pid_t) -> Set<String> {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        guard filled > 0 else { return [] }
        var paths = Set<String>()
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride)
        where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let result = proc_pidfdinfo(
                pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info,
                Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            )
            guard result > 0 else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !path.isEmpty {
                paths.insert(path)
            }
        }
        return paths
    }
}
