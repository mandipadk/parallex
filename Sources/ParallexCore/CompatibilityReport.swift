import Foundation
import ParallexKit

/// "How well does this app work in Parallex?", answered by the people who
/// use it: a GitHub issue, filled in with the facts about an instance, that
/// the person reads, finishes, and submits themselves. Nothing is sent from
/// here, and nothing personal goes in: no instance names, no paths.
public enum CompatibilityReport {
    public static let repository = "mandipadk/parallex"
    /// `.github/ISSUE_TEMPLATE/<template>`; its field IDs are the query
    /// parameters below.
    static let template = "compatibility.yml"

    /// What the report says about the instance, one fact per line.
    public static func facts(
        for manifest: InstanceManifest,
        verified: [String: Verification.Record] = Verification.load(),
        system: String = systemDescription()
    ) -> String {
        var lines: [String] = []
        let settings = manifest.effectiveSettings
        if let site = manifest.webURL {
            lines.append("Site: \(site.host ?? site.absoluteString)")
            lines.append("Made as: website (Parallex Web)")
        } else {
            let app = manifest.targetDisplayName
            let version = shortVersion(manifest.clone?.sourceVersion ?? AppCloner.version(of: URL(fileURLWithPath: manifest.targetApp)))
            lines.append("App: \(app) \(version)" + (manifest.knownTargetBundleID.map { " (\($0))" } ?? ""))
            lines.append("Made as: " + madeAs(manifest, settings: settings))
            if let bundleID = manifest.knownTargetBundleID, let record = verified[bundleID] {
                let date = record.date.formatted(.iso8601.year().month().day())
                lines.append("Isolation check: passed (\(record.version.map(shortVersion) ?? "unknown version"), \(date))")
            } else {
                lines.append("Isolation check: not run")
            }
        }
        lines.append("Parallex: \(ParallexConfig.version)")
        lines.append("macOS: \(system)")
        return lines.joined(separator: "\n")
    }

    /// A new-issue page with the facts filled in.
    public static func url(for manifest: InstanceManifest, facts: String? = nil) -> URL {
        let subject = manifest.webURL.map { $0.host ?? "Website" } ?? manifest.targetDisplayName
        // Encoded by hand: URLComponents leaves "&" and "+" as they are,
        // and an app called "This & That" would cut the report short.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        let query = [
            ("template", template),
            ("title", "\(subject): "),
            ("setup", facts ?? self.facts(for: manifest)),
        ].map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
        return URL(string: "https://github.com/\(repository)/issues/new?\(query)")!
    }

    /// "2.7032.0 (2.7032.0)" → "2.7032.0"; "4.41 (105)" stays.
    static func shortVersion(_ version: String) -> String {
        let parts = version.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[1] == "(\(parts[0]))" else { return version }
        return String(parts[0])
    }

    static func madeAs(_ manifest: InstanceManifest, settings: InstanceSettings) -> String {
        guard let clone = manifest.clone else {
            return "instance (\(manifest.mode.rawValue))"
        }
        var parts = ["own-identity copy"]
        if !clone.usesLauncher {
            parts.append("sandboxed")
            if manifest.separatedGroups != nil { parts.append("separate shared data") }
        } else if manifest.redirectedHome != nil, settings.separateLibrary != false {
            parts.append("separate Library")
            if settings.separateHiddenFolders != false { parts.append("separate hidden folders") }
        } else {
            parts.append("shared Library")
        }
        return parts.joined(separator: ", ")
    }

    /// "26.1 (arm64)".
    public static func systemDescription() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var text = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { text += ".\(version.patchVersion)" }
        #if arch(arm64)
        return text + " (arm64)"
        #else
        return text + " (x86_64)"
        #endif
    }
}
