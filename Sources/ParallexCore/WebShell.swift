import CryptoKit
import Foundation
import ParallexKit

/// Web instances: a website as an app of its own. Each is an own-identity
/// copy of "Parallex Web" (the small browser in Sources/parallex-web),
/// made like any other copy, so it gets its own Dock icon, notifications,
/// permissions and Library. The site it shows travels in its launch
/// environment (`PARALLEX_WEB_URL`).
public enum WebShell {
    public static let bundleID = "com.parallex.web"
    public static let urlVariable = "PARALLEX_WEB_URL"

    static var templateURL: URL {
        Paths.supportRoot.appendingPathComponent("web/Parallex Web.app", isDirectory: true)
    }

    /// The app web instances are copies of, built from the Parallex Web
    /// binary this Parallex ships (again whenever that binary changes).
    public static func templateApp() throws -> URL {
        let binary = try LauncherLocator.locate(helper: "parallex-web", override: "PARALLEX_WEB_SHELL")
        let stamp = try fingerprint(of: binary)
        let template = templateURL
        let plistURL = template.appendingPathComponent("Contents/Info.plist")
        if let plist = NSDictionary(contentsOf: plistURL),
           plist["CFBundleVersion"] as? String == stamp,
           plist["CFBundleShortVersionString"] as? String == ParallexConfig.version,
           FileManager.default.isExecutableFile(atPath: template.appendingPathComponent("Contents/MacOS/Parallex Web").path) {
            return template
        }
        let fm = FileManager.default
        let staging = template.deletingLastPathComponent()
            .appendingPathComponent(".building-\(UUID().uuidString)/Parallex Web.app", isDirectory: true)
        defer { try? fm.removeItem(at: staging.deletingLastPathComponent()) }
        try fm.createDirectory(at: staging.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try fm.copyItem(at: binary, to: staging.appendingPathComponent("Contents/MacOS/Parallex Web"))
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": "Parallex Web",
            "CFBundleDisplayName": "Parallex Web",
            "CFBundleExecutable": "Parallex Web",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": ParallexConfig.version,
            "CFBundleVersion": stamp,
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": true,
            "NSSupportsAutomaticGraphicsSwitching": true,
            "NSCameraUsageDescription": "The website you're using asks for the camera, for calls and video.",
            "NSMicrophoneUsageDescription": "The website you're using asks for the microphone, for calls and voice messages.",
            // Web content only: a site that isn't served over https still loads.
            "NSAppTransportSecurity": ["NSAllowsArbitraryLoadsInWebContent": true],
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: staging.appendingPathComponent("Contents/Info.plist"))
        try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", staging.path])
        // Swapped in whole, so another Parallex copying the template right
        // now never finds it half gone.
        if fm.fileExists(atPath: template.path) {
            _ = try fm.replaceItemAt(template, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: template)
        }
        return template
    }

    /// Changes whenever the binary does (so a new Parallex Web reaches every
    /// web instance), short enough for a bundle version.
    static func fingerprint(of file: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: file))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// A site as the app shows it: "https://web.whatsapp.com" stays; bare
    /// "web.whatsapp.com" gets https. Nil unless it's a web address.
    public static func normalizedURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard var components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = components.host, host.contains(".") || host == "localhost"
        else { return nil }
        // "HTTPS://Web.WhatsApp.com" → "https://web.whatsapp.com".
        components.scheme = scheme
        components.host = host.lowercased()
        return components.url
    }

    /// The site's name, or one that's free: next to WhatsApp.app (or another
    /// WhatsApp instance) it's "WhatsApp Web", then "WhatsApp Web 2", ….
    public static func freeName(
        for url: URL, outputDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    ) -> String {
        let base = suggestedName(for: url)
        let taken = Set(InstanceStore.loadAll().map { $0.name.lowercased() })
        func free(_ name: String) -> Bool {
            !taken.contains(name.lowercased())
                && !FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("\(name).app").path)
        }
        for candidate in [base, "\(base) Web"] where free(candidate) {
            return candidate
        }
        var index = 2
        while !free("\(base) Web \(index)") {
            index += 1
        }
        return "\(base) Web \(index)"
    }

    /// A name for a site's instance: "web.whatsapp.com" → "WhatsApp".
    public static func suggestedName(for url: URL) -> String {
        if let known = presets.first(where: { url.host?.lowercased() == URL(string: $0.url)?.host }) {
            return known.name
        }
        let host = (url.host ?? "Web").lowercased()
        let parts = host.split(separator: ".").filter { !["www", "web", "app", "com", "org", "net", "io", "co"].contains($0) }
        let word = parts.first.map(String.init) ?? host
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    public struct Preset: Sendable, Hashable, Identifiable {
        public let name: String
        public let url: String
        public var id: String { url }
    }

    /// Services people most often want twice, whose apps can't always be.
    public static let presets: [Preset] = [
        Preset(name: "WhatsApp", url: "https://web.whatsapp.com"),
        Preset(name: "Microsoft Teams", url: "https://teams.microsoft.com"),
        Preset(name: "Outlook", url: "https://outlook.office.com/mail/"),
        Preset(name: "Gmail", url: "https://mail.google.com"),
        Preset(name: "Slack", url: "https://app.slack.com/client"),
        Preset(name: "Discord", url: "https://discord.com/app"),
        Preset(name: "Messenger", url: "https://www.messenger.com"),
        Preset(name: "Telegram", url: "https://web.telegram.org"),
    ]
}

extension InstanceManifest {
    /// The website a web instance shows.
    public var webURL: URL? {
        effectiveSettings.webURL.flatMap(URL.init(string:))
    }

    public var isWeb: Bool { webURL != nil }

    /// What the instance is of, in words: the app's name, or a web
    /// instance's site.
    public var targetDisplayName: String {
        if let url = webURL {
            return url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "Website"
        }
        return URL(fileURLWithPath: targetApp).deletingPathExtension().lastPathComponent
    }
}
