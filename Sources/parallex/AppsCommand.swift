import ArgumentParser
import Foundation
import ParallexCore

struct Apps: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List installed apps and how well each can be duplicated."
    )

    @Flag(help: "Include apps that can't be duplicated (Apple's own).")
    var all = false

    @Flag(help: "Output machine-readable JSON.")
    var json = false

    mutating func run() throws {
        let apps = AppCatalog.scan().filter { all || $0.fit != .unsupported }
        if json {
            struct Row: Codable {
                var name, bundleID, path, fit, summary: String
                var version: String?
                var recommendsClone: Bool
                var cautions: [String]
                var verified: Bool
            }
            let rows = apps.map {
                Row(name: $0.name, bundleID: $0.bundleID, path: $0.url.path, fit: label($0.fit),
                    summary: $0.summary, version: $0.version, recommendsClone: $0.recommendsClone,
                    cautions: $0.cautions, verified: $0.verified)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(rows), as: UTF8.self))
            return
        }
        var current: CatalogApp.Fit?
        for app in apps {
            if app.fit != current {
                current = app.fit
                print("\n" + Term.bold(heading(app.fit)))
            }
            let clone = app.recommendsClone ? Term.dim("  (--clone)") : ""
            let verified = app.verified ? Term.green(" ✓ verified here") : ""
            print("  \(app.name)\(clone)\(verified)  \(Term.dim(app.summary))")
            if !app.cautions.isEmpty {
                print("    " + Term.dim(app.cautions.joined(separator: " · ")))
            }
        }
        print("")
    }

    private func heading(_ fit: CatalogApp.Fit) -> String {
        switch fit {
        case .great: "Works great"
        case .ownIdentity: "Works as its own copy"
        case .limited: "Works, with some shared data"
        case .systemParts: "Parts won't work in a copy"
        case .unsupported: "Can't be duplicated"
        }
    }

    private func label(_ fit: CatalogApp.Fit) -> String {
        switch fit {
        case .great: "great"
        case .ownIdentity: "own-identity"
        case .limited: "limited"
        case .systemParts: "system-parts"
        case .unsupported: "unsupported"
        }
    }
}
