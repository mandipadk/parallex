import ArgumentParser
import Foundation
import ParallexCore

struct Usage: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the anonymous usage report, exactly as it would be sent.",
        discussion: "Nothing is sent from here. The Parallex app sends it once a week, only if Share anonymous usage is on in Settings › About."
    )

    mutating func run() throws {
        print(String(decoding: UsageReport.make().json(), as: UTF8.self))
    }
}
