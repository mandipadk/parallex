import ArgumentParser
import Foundation
import ParallexCore

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List all Parallex instances and their status."
    )

    @Flag(help: "Output machine-readable JSON.")
    var json = false

    struct Entry: Codable {
        var manifest: InstanceManifest
        var running: Bool
        var pid: Int32?
        var wrapperExists: Bool
        var targetExists: Bool
        var problems: [String]
        /// Memory in use (bytes) while running: the app and its helpers.
        var memory: UInt64?
    }

    mutating func run() throws {
        let checked = InstanceStore.loadAll().map { ($0, InstanceStatus.check($0)) }
        let memory = InstanceMemory.measure(checked.compactMap { manifest, status in
            status.pid.map { InstanceMemory.Target(slug: manifest.slug, pid: $0, bundlePath: manifest.clone != nil ? manifest.wrapperPath : nil) }
        })
        let entries = checked.map { manifest, status in
            Entry(
                manifest: manifest,
                running: status.running,
                pid: status.pid,
                wrapperExists: !status.problems.contains(.wrapperMissing),
                targetExists: !status.problems.contains(.targetMissing),
                problems: status.problems.map(\.summary),
                memory: memory[manifest.slug]
            )
        }

        if json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(entries), as: UTF8.self))
            return
        }

        guard !entries.isEmpty else {
            print("No instances yet. Create one with:  parallex create <app> --name \"My Instance\"")
            return
        }

        let rows = entries.map { entry -> [String] in
            [
                entry.manifest.name,
                entry.manifest.isWeb ? "web"
                    : entry.manifest.clone == nil ? entry.manifest.mode.rawValue : "clone+\(entry.manifest.mode.rawValue)",
                entry.manifest.targetDisplayName,
                Paths.abbreviate(entry.manifest.wrapperPath),
                status(for: entry),
            ]
        }
        printTable(header: ["NAME", "MODE", "TARGET", "WRAPPER", "STATUS"], rows: rows)
    }

    private func status(for entry: Entry) -> String {
        if !entry.wrapperExists {
            return Term.red("wrapper missing — parallex repair")
        }
        if !entry.targetExists {
            return Term.red("original app missing")
        }
        var parts: [String] = []
        if entry.running {
            parts.append(Term.green("● running") + (entry.memory.map { " " + InstanceMemory.format($0) } ?? ""))
        }
        parts += entry.problems.map { Term.yellow($0) }
        return parts.isEmpty ? Term.dim("—") : parts.joined(separator: "  ")
    }

    private func printTable(header: [String], rows: [[String]]) {
        // Column widths are computed on unstyled text; ANSI codes would skew them.
        func visibleLength(_ text: String) -> Int {
            var length = 0
            var inEscape = false
            for character in text {
                if character == "\u{1B}" {
                    inEscape = true
                } else if inEscape {
                    if character == "m" { inEscape = false }
                } else {
                    length += 1
                }
            }
            return length
        }
        let table = [header] + rows
        var widths = [Int](repeating: 0, count: header.count)
        for row in table {
            for (index, cell) in row.enumerated() {
                widths[index] = max(widths[index], visibleLength(cell))
            }
        }
        for (rowIndex, row) in table.enumerated() {
            var line = ""
            for (index, cell) in row.enumerated() {
                let padding = String(repeating: " ", count: widths[index] - visibleLength(cell))
                line += cell + padding + (index < row.count - 1 ? "  " : "")
            }
            print(rowIndex == 0 ? Term.bold(line) : line)
        }
    }
}
