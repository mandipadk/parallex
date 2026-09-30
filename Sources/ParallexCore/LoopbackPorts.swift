import Foundation

/// The ports a copy uses in place of its app's single-instance ports (see
/// `Presets.singleInstancePorts` and ports.c in ParallexHome): chosen once,
/// kept through rebuilds, and never one another instance has.
enum LoopbackPorts {
    /// 30000–39999: below the range macOS hands out for outgoing
    /// connections, and above the usual servers'.
    static let range = 30000..<40000

    static func assign(known: [Int], slug: String, previous: [String: Int]) -> [Int: Int] {
        guard !known.isEmpty else { return [:] }
        var taken = Set(InstanceStore.loadAll().filter { $0.slug != slug }.flatMap { ($0.loopbackPorts ?? [:]).values })
        var assigned: [Int: Int] = [:]
        for port in known {
            if let kept = previous["\(port)"], range.contains(kept), !taken.contains(kept) {
                assigned[port] = kept
                taken.insert(kept)
                continue
            }
            var hash: UInt32 = 2166136261
            for byte in "\(slug):\(port)".utf8 {
                hash = (hash ^ UInt32(byte)) &* 16777619
            }
            var candidate = range.lowerBound + Int(hash % UInt32(range.count))
            while taken.contains(candidate) {
                candidate = candidate + 1 == range.upperBound ? range.lowerBound : candidate + 1
            }
            assigned[port] = candidate
            taken.insert(candidate)
        }
        return assigned
    }
}
