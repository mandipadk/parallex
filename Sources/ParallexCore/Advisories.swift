import Foundation
import ParallexKit

/// Notices from Parallex's maintainer that don't need an app update: "copies
/// of Teams 25.1 quit at launch; use the website instead", or a one-time
/// message to people on a version with a known problem. The file is signed
/// with the release key and checked against the key built into the app, so
/// no one else (not even whoever runs the server) can put words in Parallex's
/// mouth. It's data only: text, versions and links, never code.
public struct Advisories: Codable, Equatable, Sendable {
    public struct AppNotice: Codable, Equatable, Sendable {
        public var bundleID: String
        /// Which versions of the app it's about (see `VersionRange`); all
        /// when missing.
        public var versions: String?
        /// "warning" (copies have trouble) or "unsupported" (they don't work).
        public var level: String
        public var message: String
        /// A website that stands in for the app ("https://teams.microsoft.com").
        public var website: String?
    }

    public struct Message: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        /// Which Parallex versions see it; all when missing.
        public var parallex: String?
        public var title: String
        public var body: String
        public var link: String?
    }

    public var issued: Date
    public var apps: [AppNotice]
    public var messages: [Message]

    public static let url = URL(string: "https://parallex.mandip.dev/advisories.json")!
    public static let signatureURL = URL(string: "https://parallex.mandip.dev/advisories.json.sig")!

    /// Signed together with the file, so an update's signature can never
    /// pass for a notice's (and the other way round).
    public static let signingContext = Data("parallex advisories\n".utf8)

    public static func verify(_ data: Data, signature: String, publicKey: String = UpdateSignature.publicKey) -> Advisories? {
        guard UpdateSignature.verify(signingContext + data, signature: signature, publicKey: publicKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Advisories.self, from: data)
    }

    /// The file and its signature, kept together (one file, written at
    /// once, so the two can't get out of step).
    struct Kept: Codable {
        var file: Data
        var signature: String
    }

    static var cacheURL: URL { Paths.supportRoot.appendingPathComponent("advisories.kept.json") }
    /// A published file is at most this big.
    static let maxSize = 256 * 1024

    static func keptFile() -> Kept? {
        (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(Kept.self, from: $0) }
    }

    /// The last verified notices kept on this Mac (checked again on reading).
    public static func cached() -> Advisories? {
        keptFile().flatMap { verify($0.file, signature: $0.signature) }
    }

    /// The published notices, verified and kept; nil when they can't be had
    /// or don't verify. An older file than the one kept is ignored, so an
    /// old notice can't be served to hide a newer one.
    public static func fetch(session: URLSession = .shared) async -> Advisories? {
        func get(_ url: URL) async -> Data? {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("Parallex/\(ParallexConfig.version)", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count <= maxSize
            else { return nil }
            return data
        }
        guard let data = await get(url), let signatureData = await get(signatureURL) else { return nil }
        let signature = String(decoding: signatureData, as: UTF8.self)
        guard let fresh = verify(data, signature: signature) else { return nil }
        // Only a newer file replaces the one kept (or the same one again):
        // an older signed file can't be served to take a notice back.
        if let kept = keptFile(), let current = verify(kept.file, signature: kept.signature) {
            guard fresh.issued > current.issued || data == kept.file else { return current }
        }
        try? FileManager.default.createDirectory(at: Paths.supportRoot, withIntermediateDirectories: true)
        if let encoded = try? JSONEncoder().encode(Kept(file: data, signature: signature)) {
            try? encoded.write(to: cacheURL, options: .atomic)
        }
        return fresh
    }

    /// What's said about this version of an app, most serious first.
    public func notices(bundleID: String?, version: String?) -> [AppNotice] {
        guard let bundleID else { return [] }
        return apps
            .filter { $0.bundleID == bundleID && VersionRange.contains($0.versions, version) }
            .sorted { ($0.level == "unsupported" ? 0 : 1) < ($1.level == "unsupported" ? 0 : 1) }
    }

    /// Messages meant for this Parallex.
    public func messages(forParallex version: String = ParallexConfig.version) -> [Message] {
        messages.filter { VersionRange.contains($0.parallex, version) }
    }
}

/// Version ranges in notices: "*" (any), "4.2", "<4.2", "<=4.2", ">4.2",
/// ">=4.2", or "4.1...4.3" (inclusive). Several may be joined with commas
/// (any of them).
public enum VersionRange {
    public static func contains(_ range: String?, _ version: String?) -> Bool {
        guard let range = range?.trimmingCharacters(in: .whitespaces), !range.isEmpty, range != "*" else { return true }
        // A malformed range anywhere matches nothing.
        guard isValid(range) else { return false }
        guard let version = version.map(CompatibilityReport.shortVersion), !version.isEmpty else { return false }
        return range.split(separator: ",").contains { part in matches(part.trimmingCharacters(in: .whitespaces), version) }
    }

    /// A bound is a version: digits and dots, starting with a digit.
    static func isVersion(_ text: String) -> Bool {
        text.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil
    }

    /// Whether every part of a range is well formed (checked before
    /// notices are signed).
    public static func isValid(_ range: String) -> Bool {
        let trimmed = range.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "*" { return true }
        return trimmed.split(separator: ",", omittingEmptySubsequences: false).allSatisfy { part in
            let part = part.trimmingCharacters(in: .whitespaces)
            if part.contains("...") {
                let bounds = part.components(separatedBy: "...")
                return bounds.count == 2 && bounds.allSatisfy { isVersion($0.trimmingCharacters(in: .whitespaces)) }
            }
            for prefix in ["<=", ">=", "<", ">"] where part.hasPrefix(prefix) {
                return isVersion(String(part.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
            }
            return isVersion(part)
        }
    }

    static func matches(_ part: String, _ version: String) -> Bool {
        // A malformed part ("1.0...", a bare ">") matches nothing.
        guard isValid(part) else { return false }
        let compare = { (bound: String) in InstanceStatus.compareVersions(version, bound.trimmingCharacters(in: .whitespaces)) }
        if part.contains("...") {
            let bounds = part.components(separatedBy: "...")
            return compare(bounds[0]) != .orderedAscending && compare(bounds[1]) != .orderedDescending
        }
        for (prefix, test) in [
            ("<=", { (r: ComparisonResult) in r != .orderedDescending }),
            (">=", { (r: ComparisonResult) in r != .orderedAscending }),
            ("<", { (r: ComparisonResult) in r == .orderedAscending }),
            (">", { (r: ComparisonResult) in r == .orderedDescending }),
        ] where part.hasPrefix(prefix) {
            return test(compare(String(part.dropFirst(prefix.count))))
        }
        return compare(part) == .orderedSame
    }
}
