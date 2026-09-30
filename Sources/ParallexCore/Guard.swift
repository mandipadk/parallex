import Foundation

/// Guard: a copy with its own Library never needs the original app's data,
/// so nothing in it may open it, even by its full path (one saved in data
/// copied from the original, or one an app works out for itself). The
/// copy's library refuses the attempt as if it weren't permitted and
/// notes it as "blocked" in the copy's record (see recorder.c in
/// ParallexHome).
///
/// The list is what the isolation check calls the original's data, minus
/// what the user shares on purpose.
public enum Guard {
    /// Absolute paths; a folder ends in "/".
    static func locations(
        for target: AppInfo, privateHomeItems: [String]?, sharedItems: [String] = [], home: String
    ) -> [String] {
        let library = home + "/Library"
        var names = [target.url.deletingPathExtension().lastPathComponent]
        if let bundleName = target.infoPlist["CFBundleName"] as? String, !names.contains(bundleName) {
            names.append(bundleName)
        }
        var paths: [String] = []
        for folder in Presets.originalDataFolders(bundleID: target.bundleID, names: names, version: AppCloner.version(of: target.url)) {
            paths.append("\(library)/Application Support/\(folder)/")
        }
        for name in names where !name.isEmpty {
            paths.append("\(library)/Logs/\(name)/")
        }
        let id = target.bundleID
        if !id.isEmpty {
            paths += [
                "\(library)/Preferences/\(id).plist",
                "\(library)/Saved Application State/\(id).savedState/",
                "\(library)/Containers/\(id)/",
                "\(library)/Caches/\(id)/",
                "\(library)/HTTPStorages/\(id)/",
                "\(library)/HTTPStorages/\(id).binarycookies",
                "\(library)/WebKit/\(id)/",
                "\(library)/Cookies/\(id).binarycookies",
            ]
        }
        // The app's hidden folders, when the copy keeps its own.
        for item in privateHomeItems ?? [] {
            paths.append("\(home)/\(item)")
        }
        // Never Parallex's own folder (the instance's data is in it), nor
        // anything shared into the copy on purpose.
        let own = [Paths.supportRoot.resolvingSymlinksInPath().path.lowercased() + "/",
                   Paths.supportRoot.path.lowercased() + "/"]
        let shared = sharedItems.map { "\(home)/\($0)".lowercased() }
        var seen = Set<String>()
        return paths.filter { path in
            let folder = (path.hasSuffix("/") ? path : path + "/").lowercased()
            let overlapsOwn = own.contains { $0.hasPrefix(folder) || $0 == folder }
            let overlapsShared = shared.contains { folder.hasPrefix($0 + "/") || ($0 + "/").hasPrefix(folder) }
            return !overlapsOwn && !overlapsShared && seen.insert(path).inserted
        }
    }
}
