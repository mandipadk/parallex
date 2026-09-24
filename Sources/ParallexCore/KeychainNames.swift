import Foundation

/// A copy's own names for its "<App> Safe Storage" keychain items (the key
/// Electron and Chromium apps encrypt their data with). See home.c.
public enum KeychainNames {
    static func suffix(for slug: String) -> String {
        " (Parallex \(slug))"
    }

    /// Only suffixes Parallex itself makes are accepted (an imported
    /// archive's are checked): short, and plain ASCII.
    static func isValidSuffix(_ suffix: String) -> Bool {
        guard suffix.hasPrefix(" (Parallex "), suffix.hasSuffix(")"), suffix.utf8.count < 100 else { return false }
        let slug = suffix.dropFirst(" (Parallex ".count).dropLast()
        return !slug.isEmpty && slug.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Other browsers' keys, which a copy of a browser reads when importing
    /// from them: never renamed (the copy's own stays renamed).
    static let browserServices: [String: String] = [
        "com.google.Chrome": "Chrome Safe Storage",
        "org.chromium.Chromium": "Chromium Safe Storage",
        "com.brave.Browser": "Brave Safe Storage",
        "com.microsoft.edgemac": "Microsoft Edge Safe Storage",
        "com.vivaldi.Vivaldi": "Vivaldi Safe Storage",
        "com.operasoftware.Opera": "Opera Safe Storage",
        "company.thebrowser.Browser": "Arc Safe Storage",
    ]

    static func foreignServices(for app: AppInfo) -> [String] {
        browserServices.filter { !app.bundleID.hasPrefix($0.key) }.map(\.value).sorted()
    }
}
