import CryptoKit
import Foundation
import ParallexKit

/// A published Parallex release, as the updater needs it.
public struct ReleaseInfo: Sendable, Equatable, Codable {
    public var version: String
    /// Release notes (Markdown).
    public var notes: String
    public var pageURL: URL
    /// The signed app archive the updater installs.
    public var archiveURL: URL
    public var archiveSize: Int64?
    /// Base64 Ed25519 signature of the archive.
    public var signatureURL: URL
    public var publishedAt: Date?

    public init(
        version: String, notes: String, pageURL: URL, archiveURL: URL, archiveSize: Int64?,
        signatureURL: URL, publishedAt: Date?
    ) {
        self.version = version
        self.notes = notes
        self.pageURL = pageURL
        self.archiveURL = archiveURL
        self.archiveSize = archiveSize
        self.signatureURL = signatureURL
        self.publishedAt = publishedAt
    }
}

/// Where releases are published (GitHub Releases) and how to read them.
///
/// Each release carries `Parallex-<version>.zip` (the app, for the
/// updater), `Parallex-<version>.zip.sig` (its signature) and
/// `Parallex.dmg` (for people downloading from the website).
public enum UpdateFeed {
    public static let repository = "mandipadk/parallex"
    /// GitHub's latest-release endpoint; `PARALLEX_UPDATE_FEED` points
    /// elsewhere for testing the updater (signatures are still required).
    public static var latestURL: URL {
        if let override = ProcessInfo.processInfo.environment["PARALLEX_UPDATE_FEED"], let url = URL(string: override) {
            return url
        }
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    public static func archiveName(for version: String) -> String { "Parallex-\(version).zip" }

    /// Read GitHub's "latest release" response. Throws if the release has no
    /// signed archive (the updater never installs an unsigned one).
    public static func parse(_ data: Data) throws -> ReleaseInfo {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int64?
        }
        struct Release: Decodable {
            let tag_name: String
            let body: String?
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
            let published_at: String?
            let assets: [Asset]
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard release.draft != true, release.prerelease != true else {
            throw ParallexError("The latest release isn't published yet.")
        }
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        let archive = archiveName(for: version)
        guard let zip = release.assets.first(where: { $0.name == archive }),
              let signature = release.assets.first(where: { $0.name == archive + ".sig" })
        else {
            throw ParallexError("Release \(version) has no signed app archive.")
        }
        return ReleaseInfo(
            version: version,
            notes: release.body ?? "",
            pageURL: release.html_url,
            archiveURL: zip.browser_download_url,
            archiveSize: zip.size,
            signatureURL: signature.browser_download_url,
            publishedAt: release.published_at.flatMap { ISO8601DateFormatter().date(from: $0) }
        )
    }

    public static func fetchLatest(session: URLSession = .shared) async throws -> ReleaseInfo {
        var request = URLRequest(url: latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Parallex/\(ParallexConfig.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ParallexError(http.statusCode == 404
                ? "No releases are published yet."
                : "The update server answered \(http.statusCode).")
        }
        return try parse(data)
    }

    /// Whether `candidate` is a newer version than `current`.
    public static func isNewer(_ candidate: String, than current: String = ParallexConfig.version) -> Bool {
        InstanceStatus.compareVersions(candidate, current) == .orderedDescending
    }
}

/// Verifies release archives against the public key compiled into the app.
/// The private key never leaves the release machine's keychain.
public enum UpdateSignature {
    public static let publicKey = "Rr6I27BgnXlmopmP1pjqCrIYuKgHJMC5+1gowUaVVEc="

    public static func verify(_ data: Data, signature: String, publicKey: String = publicKey) -> Bool {
        let trimmed = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signatureData = Data(base64Encoded: trimmed),
              let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else {
            return false
        }
        return key.isValidSignature(signatureData, for: data)
    }
}
