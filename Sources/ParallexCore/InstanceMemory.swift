import Darwin
import Foundation

/// How much memory each running instance uses: its app process, everything
/// it started (Electron and browser helpers), and processes running from
/// inside its copy (XPC services macOS starts for it). The same "Memory"
/// figure Activity Monitor shows (physical footprint), summed.
public enum InstanceMemory {
    public struct Target: Sendable {
        public let slug: String
        public let pid: pid_t
        /// The copy's bundle path, for processes that run from inside it
        /// without being its children; nil for a plain instance, whose
        /// bundle is the original app.
        public let bundlePath: String?

        public init(slug: String, pid: pid_t, bundlePath: String?) {
            self.slug = slug
            self.pid = pid
            self.bundlePath = bundlePath
        }
    }

    /// Bytes per instance slug, for the instances given (running ones).
    public static func measure(_ targets: [Target]) -> [String: UInt64] {
        guard !targets.isEmpty else { return [:] }
        let all = IsolationCheck.allPIDs()
        var children: [pid_t: [pid_t]] = [:]
        for pid in all {
            var info = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 {
                children[pid_t(info.pbi_ppid), default: []].append(pid)
            }
        }
        let bundled = targets.contains { $0.bundlePath != nil }
        let paths: [pid_t: String] = bundled
            ? Dictionary(uniqueKeysWithValues: all.compactMap { pid in Running.executablePath(of: pid).map { (pid, $0) } })
            : [:]

        let roots = Set(targets.map(\.pid))
        var owned: [pid_t: [pid_t]] = [:]
        for pid in all {
            if let owner = responsiblePID(for: pid), roots.contains(owner) {
                owned[owner, default: []].append(pid)
            }
        }

        var result: [String: UInt64] = [:]
        var counted = Set<pid_t>()
        for target in targets {
            var members: [pid_t] = []
            var queue = [target.pid]
            while let pid = queue.popLast() {
                guard !counted.contains(pid) else { continue }
                counted.insert(pid)
                members.append(pid)
                queue += children[pid] ?? []
            }
            // What macOS holds the instance responsible for, like the web
            // pages WebKit renders in processes of their own.
            for pid in owned[target.pid] ?? [] where !counted.contains(pid) {
                counted.insert(pid)
                members.append(pid)
            }
            if let bundle = target.bundlePath {
                let prefix = bundle.hasSuffix("/") ? bundle : bundle + "/"
                for (pid, path) in paths where path.hasPrefix(prefix) && !counted.contains(pid) {
                    counted.insert(pid)
                    members.append(pid)
                }
            }
            result[target.slug] = members.reduce(0) { $0 + footprint(of: $1) }
        }
        return result
    }

    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    /// The process macOS holds responsible for another (how Activity
    /// Monitor groups an app with its helpers). Not in the public headers,
    /// so looked up at run time; without it only children and the copy's
    /// own processes count.
    private static let responsible: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let responsible else { return nil }
        let owner = responsible(pid)
        return owner > 0 && owner != pid ? owner : nil
    }

    /// Activity Monitor's "Memory" for one process (0 if it can't be read).
    static func footprint(of pid: pid_t) -> UInt64 {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? info.ri_phys_footprint : 0
    }

    /// "412 MB", "1.2 GB".
    public static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
