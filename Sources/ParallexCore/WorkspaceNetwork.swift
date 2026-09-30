import Foundation

/// A workspace's proxy: its instances go through it (Chromium and Electron
/// apps with `--proxy-server`, everything they start through the usual
/// proxy variables), and so does `parallex run`. For a client's proxy, or
/// a tunnel of your own; other apps and your own terminal don't.
public enum WorkspaceNetwork {
    static let schemes: Set<String> = ["http", "https", "socks5", "socks5h", "socks4"]

    /// `text` as a proxy address ("host:port" becomes "http://host:port"),
    /// or nil if it isn't one.
    public static func normalize(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) else { return nil }
        let full = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let url = URLComponents(string: full), let scheme = url.scheme?.lowercased(), schemes.contains(scheme),
              let host = url.host, !host.isEmpty, let port = url.port, (1...65535).contains(port),
              url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil
        else { return nil }
        return "\(scheme)://\(url.percentEncodedUser.map { $0 + (url.percentEncodedPassword.map { ":" + $0 } ?? "") + "@" } ?? "")\(host):\(port)"
    }

    /// The variables command-line tools (curl, git, npm, …) and many apps
    /// read.
    public static func environment(proxy: String) -> [String: String] {
        var variables: [String: String] = [:]
        for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] {
            variables[name] = proxy
            variables[name.lowercased()] = proxy
        }
        return variables
    }
}
