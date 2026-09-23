import AppKit
import Foundation
import ParallexCore

/// The `parallex` command ships inside the app. Linking it onto the PATH
/// (instead of installing a separate copy) means updating the app updates
/// the command too.
enum CommandLineTool {
    enum Status: Equatable {
        /// This build doesn't carry the command (a development build).
        case notBundled
        case notInstalled
        /// Linked to this app's copy.
        case linked(URL)
        /// Some other copy (e.g. from Homebrew or a source build).
        case separate(URL)
    }

    static var bundled: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("parallex"),
              FileManager.default.isExecutableFile(atPath: url.path)
        else {
            return nil
        }
        return url
    }

    /// Where to put the link, in order of preference: Homebrew's bin
    /// (writable and on the PATH on Apple silicon), /usr/local/bin if
    /// writable, then ~/.local/bin.
    static var directories: [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true),
        ]
    }

    static func status() -> Status {
        guard let bundled else { return .notBundled }
        let target = bundled.resolvingSymlinksInPath().path
        for directory in directories {
            let candidate = directory.appendingPathComponent("parallex")
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            if candidate.resolvingSymlinksInPath().path == target {
                return .linked(candidate)
            }
            return .separate(candidate)
        }
        return .notInstalled
    }

    /// Link the command into the first writable directory. A separate copy
    /// or someone else's link there goes to the Trash.
    @discardableResult
    static func install() throws -> URL {
        guard let bundled else {
            throw CocoaError(.fileNoSuchFile)
        }
        // A link into a disk image or a translocated copy breaks as soon as
        // that goes away.
        let appPath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        if appPath.hasPrefix("/Volumes/") || appPath.contains("/AppTranslocation/") {
            throw ParallexError("Move Parallex to your Applications folder first, then install the command.")
        }
        let fm = FileManager.default
        let directory = directories.first { fm.isWritableFile(atPath: $0.path) } ?? directories[2]
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("parallex")
        if let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            // Our own earlier link is simply replaced; anyone else's (say
            // Homebrew's) goes to the Trash, like a separate copy would.
            if destination.contains("Parallex.app/Contents/") {
                try fm.removeItem(at: link)
            } else {
                try fm.trashItem(at: link, resultingItemURL: nil)
            }
        } else if fm.fileExists(atPath: link.path) {
            try fm.trashItem(at: link, resultingItemURL: nil)
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: bundled)
        return link
    }

    /// Whether `directory` is on the user's shell PATH (best effort: the
    /// app's own environment doesn't include shell profile changes).
    static func isOnPath(_ directory: URL) -> Bool {
        if directory.path == "/opt/homebrew/bin" || directory.path == "/usr/local/bin" {
            return true
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").contains { $0 == directory.path }
    }
}
