import Foundation

/// Where Parallex puts what it removes: the user's Trash, so nothing is lost
/// for good. Tests and benchmarks set PARALLEX_TRASH to a folder of their
/// own, so their churn never lands in the user's Trash.
public enum Trash {
    public static func move(_ url: URL) throws {
        guard let folder = getenv("PARALLEX_TRASH").map({ String(cString: $0) }), !folder.isEmpty else {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return
        }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
    }
}
