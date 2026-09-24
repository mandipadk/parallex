import Foundation

/// `parallex://` links, for opening instances and workspaces from anywhere —
/// Shortcuts, launchers, scripts, a bookmark:
///
///     parallex://open/Claude%20Work      open (or bring forward) an instance
///     parallex://workspace/Work          open a workspace
///     parallex://show/Claude%20Work      show the instance in Parallex
///     parallex://new?app=Obsidian        start a new instance of an app
///
/// Deliberately nothing that quits, changes or removes anything: any web
/// page can ask to open a link.
public enum ParallexLink: Equatable, Sendable {
    case open(instance: String)
    case workspace(String)
    case show(instance: String)
    case new(app: String?)

    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == "parallex",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let action = components.host?.lowercased()
        else {
            return nil
        }
        // The rest of the path is one name (which may itself contain "/"
        // only percent-encoded; names can't contain "/").
        let name = components.percentEncodedPath.drop { $0 == "/" }
        let decoded = String(name).removingPercentEncoding ?? String(name)
        switch action {
        case "open" where !decoded.isEmpty:
            self = .open(instance: decoded)
        case "workspace" where !decoded.isEmpty:
            self = .workspace(decoded)
        case "show" where !decoded.isEmpty:
            self = .show(instance: decoded)
        case "new":
            // An installed app's name or bundle ID — never a path, so a web
            // page can't line up an app it just downloaded.
            let app = components.queryItems?.first { $0.name == "app" }?.value
            guard app.map({ !$0.contains("/") && !$0.hasPrefix("~") }) ?? true else { return nil }
            self = .new(app: app?.isEmpty == false ? app : nil)
        default:
            return nil
        }
    }

    public static func url(opening instance: String) -> URL {
        URL(string: "parallex://open/" + (instance.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? instance))!
    }

    public static func url(openingWorkspace name: String) -> URL {
        URL(string: "parallex://workspace/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? name))!
    }
}
