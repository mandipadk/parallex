import ArgumentParser
import Foundation
import ParallexCore

/// Every instance at once: the version of its app it runs, how its
/// isolation has held since its record began, what Guard kept out, its
/// snapshots, and anything that needs doing.
struct Health: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "How every instance is doing: its app's version, isolation, Guard, snapshots and problems."
    )

    @Flag(help: "Print JSON.")
    var json = false

    struct Row: Codable {
        var name: String
        var version: String?
        var pinned: Bool
        var recordedSince: Date?
        var leaks: Int?
        var keptOut: Int?
        var guardOn: Bool
        var snapshots: Int
        var latestSnapshot: Date?
        var dailySnapshots: Bool
        var problems: [String]
    }

    mutating func run() throws {
        let rows = InstanceStore.loadAll().map { manifest -> Row in
            let settings = manifest.effectiveSettings
            let recorded = IsolationCheck.recorded(manifest)
            let snapshots = Snapshots.list(manifest)
            return Row(
                name: manifest.name,
                version: manifest.clone?.sourceVersion,
                pinned: settings.pinnedVersion != nil,
                recordedSince: recorded?.recordedSince,
                leaks: recorded.map { $0.findings(in: .leak).count },
                keptOut: recorded.map { $0.blocked.count },
                guardOn: !(manifest.guardedPaths ?? []).isEmpty,
                snapshots: snapshots.count,
                latestSnapshot: snapshots.first?.date,
                dailySnapshots: settings.dailySnapshots == true,
                problems: InstanceStatus.check(manifest).problems.map(\.summary)
            )
        }
        if json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(rows), as: UTF8.self))
            return
        }
        guard !rows.isEmpty else {
            print("No instances yet.")
            return
        }
        let day = { (date: Date) in date.formatted(.dateTime.month(.abbreviated).day()) }
        let table = rows.map { row -> [String] in
            let version = row.version.map { ($0.components(separatedBy: " (").first ?? $0) + (row.pinned ? ", staying" : "") }
                ?? "the app itself"
            let isolation: String
            if let leaks = row.leaks, leaks > 0 {
                isolation = Term.red("\(leaks) of the original's files used")
            } else if let since = row.recordedSince {
                isolation = Term.green("clean") + " since \(day(since))"
            } else {
                isolation = Term.dim("not recorded")
            }
            let guardText = row.guardOn ? ((row.keptOut ?? 0) > 0 ? "on, kept out \(row.keptOut ?? 0)" : "on") : Term.dim("off")
            var snapshots = row.snapshots == 0 ? Term.dim("none") : "\(row.snapshots), latest \(day(row.latestSnapshot ?? Date()))"
            if row.dailySnapshots { snapshots += ", daily" }
            let problems = row.problems.isEmpty ? Term.dim("—") : Term.yellow(row.problems.joined(separator: "; "))
            return [row.name, version, isolation, guardText, snapshots, problems]
        }
        printTable(header: ["NAME", "APP VERSION", "ISOLATION", "GUARD", "SNAPSHOTS", "NEEDS"], rows: table)
    }

    private func printTable(header: [String], rows: [[String]]) {
        // Widths from the visible text: colour codes don't take up room.
        func visible(_ text: String) -> Int {
            text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).count
        }
        var widths = header.map(\.count)
        for row in rows {
            for (index, cell) in row.enumerated() { widths[index] = max(widths[index], visible(cell)) }
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { index, cell in
                index == cells.count - 1 ? cell : cell + String(repeating: " ", count: widths[index] - visible(cell) + 2)
            }.joined()
        }
        print(Term.dim(line(header)))
        rows.forEach { print(line($0)) }
    }
}
