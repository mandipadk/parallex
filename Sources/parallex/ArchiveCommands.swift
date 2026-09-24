import ArgumentParser
import Foundation
import ParallexCore

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save an instance — settings and data — to a .parallex file.",
        discussion: "For backups, or to move an instance to another Mac with `parallex import`."
    )

    @Argument(help: "The instance.")
    var instance: String

    @Option(name: .shortAndLong, help: "Where to write it (default: ./<name>.parallex).")
    var output: String?

    mutating func run() throws {
        let manifest = try lookupInstance(instance)
        let requested = URL(fileURLWithPath: ((output ?? "\(manifest.name).\(InstanceArchive.fileExtension)") as NSString)
            .expandingTildeInPath)
        let destination = try InstanceArchive.export(manifest, to: requested)
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        print("\(Term.green("✓")) Exported “\(manifest.name)” to \(Paths.abbreviate(destination.path)) (\(InstanceStorage.format(size)))")
    }
}

struct Import: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Recreate an instance from a .parallex file.",
        discussion: "The instance's app is rebuilt for this Mac; it needs the same app installed."
    )

    @Argument(help: "The .parallex file.")
    var file: String

    @Option(help: "Name for the instance (default: the exported name, or the next free one).")
    var name: String?

    @Option(help: "Directory the instance app is written to.")
    var out: String = "/Applications"

    @Flag(help: """
    Also import the file's extra launch arguments and environment. Only for files you trust: \
    they run with the app. Variables that load code (DYLD_*, NODE_OPTIONS, …) are never imported.
    """)
    var keepExtras = false

    mutating func run() throws {
        let result = try InstanceArchive.import(
            from: URL(fileURLWithPath: (file as NSString).expandingTildeInPath),
            name: name,
            keepExtras: keepExtras,
            outputDirectory: URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true)
        )
        printResultSummary(result, verb: "Imported")
    }
}
