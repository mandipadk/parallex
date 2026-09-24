import ArgumentParser
import Foundation
import ParallexCore

struct Notices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the notices Parallex has from its maintainer (signed and checked, as the app does)."
    )

    mutating func run() async throws {
        guard let advisories = await Advisories.fetch() ?? Advisories.cached() else {
            throw ValidationError("Couldn't get notices that check out (offline, or not signed with Parallex's key).")
        }
        print("Notices issued \(advisories.issued.formatted(date: .abbreviated, time: .shortened)), signature checked.")
        if advisories.apps.isEmpty && advisories.messages.isEmpty {
            print("Nothing to say right now.")
        }
        for notice in advisories.apps {
            print("\n\(notice.level == "unsupported" ? "✗" : "!") \(notice.bundleID)\(notice.versions.map { " (\($0))" } ?? "")")
            print("  \(notice.message)")
            if let website = notice.website { print("  Instead: \(website)") }
        }
        for message in advisories.messages {
            print("\n• \(message.title)\(message.parallex.map { " (Parallex \($0))" } ?? "")")
            print("  \(message.body)")
        }
    }
}
