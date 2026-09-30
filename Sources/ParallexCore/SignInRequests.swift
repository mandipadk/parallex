import Foundation

/// Which copy started a sign-in. Signing in to an app in a browser ends
/// with the browser opening a link in the app's scheme (`claude://…`)
/// that carries back the `state` the app put in its sign-in request. When
/// a copy opens that request, its library notes the state (signin.m in
/// ParallexHome), and so does Parallex Links when it's the browser that
/// opens it; the link that comes back then goes to the copy that asked,
/// whatever was used in between.
public enum SignInRequests {
    /// How long a request is remembered (a sign-in takes minutes).
    static let window: TimeInterval = 30 * 60

    static func file(slug: String) -> URL {
        Paths.instanceDir(slug: slug).appendingPathComponent("signin.log")
    }

    /// The request's `state`, when `url` is a sign-in request or the link
    /// coming back from one (in its query, or its fragment for implicit
    /// flows).
    public static func state(in url: URL) -> String? {
        let items = queryItems(of: url)
        return items["state"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether `url` looks like the start of a sign-in (OAuth): a `state`
    /// and one of the parameters every such request has.
    public static func isRequest(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        let items = queryItems(of: url)
        return state(in: url) != nil
            && (items["client_id"] != nil || items["redirect_uri"] != nil || items["response_type"] != nil)
    }

    private static func queryItems(of url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
        var items: [String: String] = [:]
        for item in components.queryItems ?? [] where items[item.name] == nil {
            items[item.name] = item.value ?? ""
        }
        if let fragment = components.fragment, fragment.contains("=") {
            var parsed = URLComponents()
            parsed.percentEncodedQuery = fragment
            for item in parsed.queryItems ?? [] where items[item.name] == nil {
                items[item.name] = item.value ?? ""
            }
        }
        return items
    }

    /// Note that the instance `slug` asked for a sign-in with `state`.
    public static func record(state: String, slug: String, at date: Date = Date()) {
        let url = file(slug: slug)
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 16_384 {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\(Int(date.timeIntervalSince1970))\t\(state)\n".utf8))
    }

    /// The instance that asked for the sign-in with `state` lately.
    public static func requester(of state: String, manifests: [InstanceManifest], now: Date = Date()) -> String? {
        var newest: (slug: String, date: Date)?
        for manifest in manifests {
            guard let text = try? String(contentsOf: file(slug: manifest.slug), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let fields = line.split(separator: "\t", maxSplits: 1)
                guard fields.count == 2, String(fields[1]) == state, let seconds = TimeInterval(fields[0]) else { continue }
                let date = Date(timeIntervalSince1970: seconds)
                guard now.timeIntervalSince(date) <= window, date > newest?.date ?? .distantPast else { continue }
                newest = (manifest.slug, date)
            }
        }
        return newest?.slug
    }

    /// The copies a link coming back from a sign-in may go to: the one that
    /// asked, when one did. When none noted it, all of them, as before:
    /// a copy can open a sign-in page in ways its library doesn't see (the
    /// `open` command, say), so not having noted it proves nothing.
    public static func narrow(
        _ candidates: [LinkRouting.Candidate], for url: URL, manifests: [InstanceManifest], now: Date = Date()
    ) -> [LinkRouting.Candidate] {
        guard let state = state(in: url),
              let slug = requester(of: state, manifests: manifests, now: now),
              let asked = candidates.first(where: { $0.slug == slug })
        else { return candidates }
        return [asked]
    }
}
