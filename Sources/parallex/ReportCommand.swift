import AppKit
import ArgumentParser
import Foundation
import ParallexCore

struct Report: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Tell others how an app works in Parallex: opens a GitHub report with the details filled in.",
        discussion: "Nothing is sent: you read, finish and submit the report yourself. It names the app, its version and how the instance was made; never the instance's name or any paths."
    )

    @Argument(help: "Instance name or slug.")
    var instance: String

    @Flag(help: "Print the report's details and link instead of opening it.")
    var print = false

    mutating func run() throws {
        let manifest = try lookupInstance(instance)
        let facts = CompatibilityReport.facts(for: manifest)
        let url = CompatibilityReport.url(for: manifest, facts: facts)
        Swift.print(facts)
        Swift.print("")
        if print {
            Swift.print(url.absoluteString)
        } else {
            Swift.print(Term.dim("Opening the report on GitHub — nothing is sent until you submit it there."))
            NSWorkspace.shared.open(url)
        }
    }
}
