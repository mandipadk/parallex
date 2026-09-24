import ArgumentParser
import Foundation
import ParallexCore

struct Check: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Verify a running instance's isolation from the files it has open.",
        discussion: """
        Lists files the instance's processes have open in your home folder and \
        flags any that belong to the original app's data. It's a snapshot: use \
        the instance for a bit first, and re-run after sign-in or heavy use.
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
        let report = try IsolationCheck.run(manifest)

        if json {
            struct Output: Codable {
                var instance: String
                var processes: Int
                var files: Int
                var clean: Bool
                var findings: [IsolationReport.Finding]
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let output = Output(
                instance: manifest.name, processes: report.processCount, files: report.fileCount,
                clean: report.isClean, findings: report.findings
            )
            print(String(decoding: try encoder.encode(output), as: UTF8.self))
            if !report.isClean { throw ExitCode(2) }
            return
        }

        let isolated = report.findings(in: .isolated).count
        print("\(Term.bold(manifest.name)): \(report.processCount) processes, "
            + "\(isolated) open files inside the instance directory")
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
