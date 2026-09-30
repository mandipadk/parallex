import Foundation
import ParallexKit

/// Something's Off: a note to Parallex's maker, in the sender's own words,
/// with a few facts about the instance it's about, if one is picked. The
/// whole note is shown before it goes; nothing is sent without Send. Never
/// the instance's name, paths, or a non-well-known app's identity.
public enum Feedback {
    public static let endpoint = URL(string: "https://parallex.mandip.dev/api/v1/feedback")!

    public struct Instance: Codable, Sendable, Equatable {
        public var kind: String
        /// A well-known app's bundle ID, "other" otherwise.
        public var app: String
        public var appVersion: String?
        public var facts: Facts
    }

    /// How the instance has been doing, as far as this Mac knows.
    public struct Facts: Codable, Sendable, Equatable {
        public var quitsAtLaunch: Int?
        /// "clean", "leak" or "unchecked".
        public var isolation: String
        public var running: Bool
        public var guard_: Bool
        public var separateKeychain: Bool
        public var pinnedVersion: Bool
        public var sharesSettings: Bool
        /// What it needs (a repair, an update), by name.
        public var problems: [String]

        enum CodingKeys: String, CodingKey {
            case quitsAtLaunch, isolation, running, separateKeychain, pinnedVersion, sharesSettings, problems
            case guard_ = "guard"
        }
    }

    public struct Note: Codable, Sendable, Equatable {
        public var message: String
        public var contact: String?
        public var version: String
        public var os: String
        public var arch: String
        public var instance: Instance?
    }

    /// The facts about `manifest` that go with a note.
    public static func instance(_ manifest: InstanceManifest) -> Instance {
        let facts = Telemetry.facts(of: manifest)
        let original = manifest.knownTargetBundleID
        let quits = original.flatMap { Compatibility.load()[$0]?.quickExits }
        let isolation: String
        if let report = IsolationCheck.recorded(manifest) {
            isolation = report.isClean ? "clean" : "leak"
        } else if let original, Verification.load()[original] != nil {
            isolation = "clean"
        } else {
            isolation = "unchecked"
        }
        let settings = manifest.effectiveSettings
        let problems = InstanceStatus.check(manifest).problems.map { problem in
            String(String(describing: problem).prefix { $0 != "(" })
        }
        return Instance(
            kind: facts["kind"] ?? "wrapper",
            app: facts["app"] ?? "other",
            appVersion: facts["version"],
            facts: Facts(
                quitsAtLaunch: quits,
                isolation: isolation,
                running: Running.isRunning(manifest),
                guard_: manifest.guardedPaths?.isEmpty == false,
                separateKeychain: manifest.instanceKeychain != nil,
                pinnedVersion: settings.pinnedVersion != nil,
                sharesSettings: manifest.sharedSettings?.isEmpty == false,
                problems: Array(problems.prefix(8))
            )
        )
    }

    /// An address Parallex's server will keep (the same rule it uses).
    public static func isValidContact(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^[A-Za-z0-9._+-]{1,64}@[A-Za-z0-9.-]{1,180}\.[A-Za-z]{2,24}$"#, options: .regularExpression) != nil
    }

    public static func make(message: String, contact: String?, about manifest: InstanceManifest?) -> Note {
        let usage = UsageReport.make(manifests: [])
        let contact = contact?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Note(
            message: String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000)),
            contact: contact.map(isValidContact) == true ? contact : nil,
            version: ParallexConfig.version,
            os: usage.os,
            arch: usage.arch,
            instance: manifest.map(instance)
        )
    }

    public static func json(_ note: Note) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(note)) ?? Data()
    }

    public static func send(_ note: Note, session: URLSession = .shared) async throws {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Parallex/\(ParallexConfig.version)", forHTTPHeaderField: "User-Agent")
        request.httpBody = json(note)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        if !(200..<300).contains(http.statusCode) {
            let reason = String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ParallexError(reason.isEmpty ? "It didn't go through (\(http.statusCode)). Try again in a minute." : reason)
        }
    }
}
