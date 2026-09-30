import Foundation

/// A workspace's proxy: its instances go through it (Chromium and Electron
/// apps with `--proxy-server`, everything they start through the usual
/// proxy variables), and so does `parallex run`. For a client's proxy, or
/// a tunnel of your own; other apps and your own terminal don't.
public enum WorkspaceNetwork {
    static let schemes: Set<String> = ["http", "https", "socks5", "socks5h", "socks4"]

    /// `text` as a proxy address ("host:port" becomes "http://host:port"),
    /// or nil if it isn't one. Never with a user and password: those would
    /// sit in every process's arguments and environment (an app asks for a
    /// proxy's password itself).
    public static func normalize(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) else { return nil }
        let full = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let url = URLComponents(string: full), let scheme = url.scheme?.lowercased(), schemes.contains(scheme),
              let host = url.host, !host.isEmpty, let port = url.port, (1...65535).contains(port),
              url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil
        else { return nil }
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(bracketed):\(port)"
    }

    /// The variables command-line tools (curl, git, npm, …) and many apps
    /// read.
    /// (This Mac's own addresses stay direct, as a local server should.)
    public static func environment(proxy: String, base: [String: String] = [:]) -> [String: String] {
        var variables: [String: String] = [:]
        for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] {
            variables[name] = proxy
            variables[name.lowercased()] = proxy
        }
        if base["NO_PROXY"] == nil && base["no_proxy"] == nil {
            variables["NO_PROXY"] = localAddresses
            variables["no_proxy"] = localAddresses
        }
        return variables
    }

    static let localAddresses = "localhost,127.0.0.1,::1"

    /// What Chromium's --proxy-server takes: it knows socks5, which already
    /// resolves names through the proxy, not socks5h.
    public static func chromiumSwitch(proxy: String) -> String {
        proxy.hasPrefix("socks5h://") ? "socks5://" + proxy.dropFirst("socks5h://".count) : proxy
    }
}
