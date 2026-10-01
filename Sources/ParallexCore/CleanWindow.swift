import Foundation

/// Open in a Clean Window (the Services menu): a link opened in a website
/// instance made for it and thrown away once it's closed: no cookies,
/// history or sign-ins of yours on the way in, nothing kept on the way out.
public enum CleanWindow {
    /// The web address in what was selected or sent: the first http(s) link
    /// in it, or the text itself when it's an address. Nothing else (a
    /// file, a custom scheme, an email address) is opened this way.
    public static func link(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4096 else { return nil }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let matches = detector.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
            if let url = matches.lazy.compactMap(\.url).first(where: isWeb) {
                return url
            }
        }
        guard !trimmed.contains(where: \.isWhitespace), let url = WebShell.normalizedURL(trimmed), isWeb(url) else { return nil }
        return url
    }

    /// The first web address among several candidates (what a pasteboard
    /// holds: links, then text).
    public static func link(in candidates: [String]) -> URL? {
        candidates.lazy.compactMap { link(in: $0) }.first
    }

    private static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    /// "Clean Window", or "Clean Window 2" and on when that's taken.
    public static func freeName(taken: Set<String>) -> String {
        let base = "Clean Window"
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }
}
