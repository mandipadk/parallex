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
    /// GitHub's latest-release endpoint, asked directly when Parallex's own
    /// server doesn't answer.
    public static let githubURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    /// Parallex's server: GitHub's answer passed through, and the check
    /// counted (see `CheckActivity` for what it's told). Archives are
    /// verified against the key in the app either way.
    public static let missionControlURL = URL(string: "https://parallex.mandip.dev/api/v1/releases/latest")!

    /// Where to ask; `PARALLEX_UPDATE_FEED` points elsewhere for testing the
    /// updater (signatures are still required).
    public static var latestURLs: [URL] {
        if let override = ProcessInfo.processInfo.environment["PARALLEX_UPDATE_FEED"], let url = URL(string: override) {
            return [url]
        }
        return [missionControlURL, githubURL]
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

    /// The latest release. `counted` hears as soon as Parallex's server has
    /// taken the check (and the activity it was told), even when the rest
    /// of the check then fails, so it's never told twice.
    public static func fetchLatest(
        activity: [String] = [], session: URLSession = .shared, counted: (@Sendable () -> Void)? = nil
    ) async throws -> (release: ReleaseInfo, counted: Bool) {
        var lastError: Error = ParallexError("The update server didn't answer.")
        for url in latestURLs {
            let ours = url == missionControlURL
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: ours ? 10 : 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Parallex/\(ParallexConfig.version)", forHTTPHeaderField: "User-Agent")
            if ours {
                for (field, value) in CheckActivity.headers(periods: activity) {
                    request.setValue(value, forHTTPHeaderField: field)
                }
            }
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw ParallexError(http.statusCode == 404
                        ? "No releases are published yet."
                        : "The update server answered \(http.statusCode).")
                }
                if ours { counted?() }
                return (try parse(data), ours)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Whether `candidate` is a newer version than `current`.
    public static func isNewer(_ candidate: String, than current: String = ParallexConfig.version) -> Bool {
        InstanceStatus.compareVersions(candidate, current) == .orderedDescending
    }
}

/// Everything an update check tells Parallex's server, and nothing else:
/// this version, the macOS version, the chip, and which of "first check
/// ever / today / this week / this month" it is. No identifier, so the
/// server can count Macs without being able to tell them apart.
public struct CheckActivity: Codable, Equatable, Sendable {
    public var day: String?
    public var week: String?
    public var month: String?

    public init(day: String? = nil, week: String? = nil, month: String? = nil) {
        self.day = day
        self.week = week
        self.month = month
    }

    /// What this check is the first of, and the record to keep once the
    /// server has it. `checkedBefore`: a Parallex from before these
    /// records existed has checked already, so it isn't new. Days, weeks
    /// and months are UTC ones, like the server's.
    public func periods(at date: Date, checkedBefore: Bool) -> (periods: [String], next: CheckActivity) {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = TimeZone(identifier: "UTC")!
        let parts = iso.dateComponents([.year, .month, .day, .yearForWeekOfYear, .weekOfYear], from: date)
        let next = CheckActivity(
            day: String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
            week: String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0),
            month: String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
        )
        var periods: [String] = []
        if self == CheckActivity(), !checkedBefore { periods.append("new") }
        if day != next.day { periods.append("day") }
        if week != next.week { periods.append("week") }
        if month != next.month { periods.append("month") }
        return (periods, next)
    }

    /// The request headers that carry it.
    public static func headers(periods: [String]) -> [(String, String)] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return [
            ("X-Parallex-Version", ParallexConfig.version),
            ("X-Parallex-OS", "\(os.majorVersion).\(os.minorVersion)"),
            ("X-Parallex-Arch", arch),
            ("X-Parallex-Active", periods.joined(separator: ",")),
        ]
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
