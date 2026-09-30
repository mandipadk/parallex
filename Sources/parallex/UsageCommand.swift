import ArgumentParser
import Foundation
import ParallexCore

struct Usage: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the anonymous usage report, exactly as it would be sent, or turn sharing on or off.",
        discussion: """
        Nothing is sent from here. While this Mac shares usage, the Parallex app sends the report once a day, \
        with its update check. What's in it: https://parallex.mandip.dev/privacy
        """
    )

    @Flag(inversion: .prefixedNo, help: "Turn sharing on (--share) or off (--no-share).")
    var share: Bool?

    mutating func run() throws {
        if let share {
            Telemetry.setConsent(share ? .shared : .declined)
            print(share ? "This Mac shares anonymous usage." : "This Mac doesn't share usage. Nothing waiting to be sent was kept.")
            return
        }
        let state = switch Telemetry.consent {
        case .shared: "Shared daily by the Parallex app."
        case .declined: "Not shared (turn on with --share)."
        case .undecided: "Not shared yet: the Parallex app asks first."
        }
        FileHandle.standardError.write(Data((state + "\n").utf8))
        print(String(decoding: Telemetry.json(Telemetry.make(preview: true)), as: UTF8.self))
    }
}
