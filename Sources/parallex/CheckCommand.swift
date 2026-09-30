import ArgumentParser
import Foundation
import ParallexCore

struct Check: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Verify an instance's isolation from the files it uses.",
        discussion: """
        Lists files the instance's processes have open in your home folder and \
        flags any that belong to the original app's data. A copy with its own \
        Library also records everything of yours it opens, from its first \
        launch on, so its check covers all of that too, and works while it \
        isn't running. Other instances are checked from a snapshot: use them \
        for a bit first.
        """
    )

    @Argument(help: "The instance's name or slug.")
    var instance: String

    @Flag(help: "Also list files outside the app's known data locations.")
    var verbose = false

    @Flag(help: "Output machine-readable JSON.")
    var json = false

    mutating func run() throws {
        let manifest = try lookupInstance(instance)
        let running = Running.isRunning(manifest)
        let report = try !running ? (IsolationCheck.recorded(manifest) ?? IsolationCheck.run(manifest)) : IsolationCheck.run(manifest)

        if json {
            struct Output: Codable {
                var instance: String
                var processes: Int
                var files: Int
                var clean: Bool
                var recordedSince: Date?
                var findings: [IsolationReport.Finding]
                var blocked: [String]
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let output = Output(
                instance: manifest.name, processes: report.processCount, files: report.fileCount,
                clean: report.isClean, recordedSince: report.recordedSince, findings: report.findings,
                blocked: report.blocked
            )
            print(String(decoding: try encoder.encode(output), as: UTF8.self))
            if !report.isClean { throw ExitCode(2) }
            return
        }

        let isolated = report.findings(in: .isolated).count
        let since = report.recordedSince.map { $0.formatted(date: .abbreviated, time: .shortened) }
        if running {
            print("\(Term.bold(manifest.name)): \(report.processCount) processes, "
                + "\(isolated) open files inside the instance directory")
        } else {
            print("\(Term.bold(manifest.name)) isn't running: what it opened of yours, as its recorder noted it")
        }
        if let since {
            print(Term.dim("Recorded since \(since)."))
        }
        let sections: [(IsolationReport.Category, String)] = [
            (.leak, Term.red("Leaks — the original's data in use")),
            (.sharedByIdentity, Term.yellow("Shared, can't be separated")),
            (.sharedByChoice, "Shared on purpose"),
        ]
        for (category, title) in sections {
            let findings = report.findings(in: category)
            guard !findings.isEmpty else { continue }
            print("\n\(title)")
            for finding in findings {
                print("  \(Paths.abbreviate(finding.path))  \(Term.dim(finding.reason))")
            }
        }
        if !report.blocked.isEmpty {
            print("\nKept out by Guard")
            for path in report.blocked {
                print("  \(Paths.abbreviate(path))")
            }
        }
        let suggestions = PrivateSuggestions.suggestions(for: manifest)
        if !suggestions.isEmpty {
            print("\nWritten to through your home (shared with everything else)")
            for suggestion in suggestions {
                print("  ~/\(suggestion.item)  " + Term.dim("\(suggestion.writes) writes; keep it to this instance: "
                    + "parallex edit \"\(manifest.name)\" --private \(suggestion.item)"))
            }
        }
        let other = report.findings(in: .other)
        if verbose, !other.isEmpty {
            print("\nOther files in your home folder")
            for finding in other {
                print("  \(Paths.abbreviate(finding.path))")
            }
        } else if !other.isEmpty {
            print(Term.dim("\n\(other.count) other files in your home folder (--verbose to list)."))
        }
        print("")
        if report.isClean {
            print("\(Term.green("✓")) No leaks into the original app's data found.")
        } else {
            print("\(Term.red("✗")) This instance is using the original app's data.")
            if report.separationInactive {
                print("  macOS didn't load Parallex's library into the copy. Quit it and open it again;"
                    + " if that doesn't help, `parallex repair \"\(manifest.name)\"`.")
            } else if manifest.settings == nil || InstanceStatus.check(manifest).problems.contains(where: {
                if case .wrapperOutdated = $0 { return true }
                return false
            }) {
                print("  Its wrapper predates the current recipes — `parallex repair \"\(manifest.name)\"` may fix this.")
            }
            throw ExitCode(2)
        }
    }
}
