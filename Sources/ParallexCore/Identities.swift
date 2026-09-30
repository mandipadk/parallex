import Foundation

/// Who you are to your command-line tools in a home: read from their
/// settings files, without running them (running git on a Mac without the
/// developer tools asks to install them) and without the network. Used to
/// show a workspace's persona beside you.
public enum Identities {
    public struct Entry: Sendable, Hashable, Identifiable {
        /// "git", "GitHub CLI", …
        public let tool: String
        /// Who, as the tool has it; nil when it isn't set up there.
        public let identity: String?
        public var id: String { tool }
    }

    /// What each tool says in `home`, in a fixed order.
    public static func read(home: URL) -> [Entry] {
        [
            Entry(tool: "git", identity: git(home)),
            Entry(tool: "GitHub CLI", identity: gh(home)),
            Entry(tool: "AWS", identity: aws(home)),
            Entry(tool: "Kubernetes", identity: kube(home)),
            Entry(tool: "Google Cloud", identity: gcloud(home)),
            Entry(tool: "npm", identity: npm(home)),
        ]
    }

    private static func text(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count < 1_000_000 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// An INI-style file's `key` in `section` (the last one wins, as git
    /// and the cloud tools read them), with the files it includes first.
    private static func iniValue(_ url: URL, section: String, key: String, depth: Int = 0) -> String? {
        guard depth < 4, let text = text(url) else { return nil }
        var current = ""
        var value: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.hasPrefix(";") || line.isEmpty { continue }
            if line.hasPrefix("[") {
                current = line.dropFirst().prefix { $0 != "]" }.trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if current == "include", parts[0].lowercased() == "path" {
                var path = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if path.hasPrefix("~/") { path = url.deletingLastPathComponent().path + "/" + path.dropFirst(2) }
                if let included = iniValue(URL(fileURLWithPath: path), section: section, key: key, depth: depth + 1) {
                    value = included
                }
            } else if current == section, parts[0].lowercased() == key {
                value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return value
    }

    static func git(_ home: URL) -> String? {
        // Git reads the XDG file first, then ~/.gitconfig, which wins.
        let xdg = iniValue(home.appendingPathComponent(".config/git/config"), section: "user", key: "email")
        let own = iniValue(home.appendingPathComponent(".gitconfig"), section: "user", key: "email")
        return own ?? xdg
    }

    static func gh(_ home: URL) -> String? {
        guard let text = text(home.appendingPathComponent(".config/gh/hosts.yml")) else { return nil }
        // "github.com:\n    user: name" (the active account, in every
        // version of the file).
        var host: String?
        var found: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if !line.hasPrefix(" "), line.hasSuffix(":") {
                host = String(line.dropLast())
            } else if let host, line.hasPrefix("    user:") {
                let user = line.dropFirst("    user:".count).trimmingCharacters(in: .whitespaces)
                found.append(host == "github.com" ? user : "\(user) on \(host)")
            }
        }
        return found.isEmpty ? nil : found.joined(separator: ", ")
    }

    static func aws(_ home: URL) -> String? {
        let config = home.appendingPathComponent(".aws/config")
        let credentials = home.appendingPathComponent(".aws/credentials")
        guard text(config) != nil || text(credentials) != nil else { return nil }
        let account = iniValue(config, section: "default", key: "sso_account_id")
        let role = iniValue(config, section: "default", key: "sso_role_name")
        if let account {
            return "account \(account)" + (role.map { ", \($0)" } ?? "")
        }
        if let key = iniValue(credentials, section: "default", key: "aws_access_key_id"), key.count > 4 {
            return "key …\(key.suffix(4))"
        }
        return "set up, no default profile"
    }

    static func kube(_ home: URL) -> String? {
        guard let text = text(home.appendingPathComponent(".kube/config")) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("current-context:") {
            let context = line.dropFirst("current-context:".count).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return context.isEmpty ? nil : context
        }
        return nil
    }

    static func gcloud(_ home: URL) -> String? {
        let root = home.appendingPathComponent(".config/gcloud")
        let active = text(root.appendingPathComponent("active_config"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "default"
        return iniValue(root.appendingPathComponent("configurations/config_\(active)"), section: "core", key: "account")
    }

    static func npm(_ home: URL) -> String? {
        guard let text = text(home.appendingPathComponent(".npmrc")) else { return nil }
        let registries = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("//"), line.contains(":_authToken") || line.contains(":_auth") else { return nil }
            return line.dropFirst(2).split(separator: "/").first.map(String.init)
        }
        return registries.isEmpty ? nil : "signed in to " + registries.joined(separator: ", ")
    }
}
