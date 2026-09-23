import ArgumentParser
import Foundation
import ParallexCore

struct Links: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Send sign-in links to the right running copy of an app.",
        discussion: """
        Apps finish sign-in by opening a link in their own scheme (claude://, \
        cursor://…). With several copies running, macOS gives that link to an \
        arbitrary one. With routing on, "Parallex Links" handles those schemes \
        and passes each link to the copy you used most recently (or asks).

        macOS may ask you to confirm the new default handler, and the first \
        time a link is passed on, to allow Parallex Links to control the app.
        """,
        subcommands: [Status.self, Enable.self, Disable.self],
        defaultSubcommand: Status.self
    )

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show which link schemes are routed.")

        mutating func run() throws {
            let config = LinkRouting.loadConfiguration()
            let schemes = LinkRouting.routableSchemes(InstanceStore.loadAll())
            print("Link routing: \(config.enabled ? Term.green("on") : "off")"
                + (config.enabled && config.alwaysAsk ? " (asks every time)" : ""))
            if schemes.isEmpty {
                print("None of your instances' apps use custom link schemes.")
                return
            }
            for (scheme, app) in schemes.sorted(by: { $0.key < $1.key }) {
                let routed = LinkRouting.isRouting(scheme)
                let handler = LinkRouting.currentHandler(for: scheme).map { Paths.abbreviate($0.path) } ?? "none"
                let state = routed ? Term.green("routed") : (config.enabled ? Term.yellow("not routed") : Term.dim("—"))
                print("  \(scheme)://  \(state)  \(Term.dim("\(URL(fileURLWithPath: app).lastPathComponent) · handler: \(handler)"))")
            }
            if config.enabled, schemes.keys.contains(where: { !LinkRouting.isRouting($0) }) {
                print("Some schemes aren't routed: apps reclaim their scheme when they start, and Parallex.app")
                print("takes it back while it's running. Run `parallex links enable` to route them now.")
            }
        }
    }

    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn link routing on (or refresh it for new instances).")

        @Flag(help: "Ask which copy to use whenever several are running.")
        var ask = false

        mutating func run() async throws {
            var config = try await LinkRouting.enable(
                routerBinary: try LauncherLocator.locateRouter(), manifests: InstanceStore.loadAll()
            )
            if ask != config.alwaysAsk {
                config.alwaysAsk = ask
                try LinkRouting.setAlwaysAsk(ask)
            }
            let schemes = config.schemes.keys.sorted()
            print("\(Term.green("✓")) Routing \(schemes.map { "\($0)://" }.joined(separator: ", "))")
            print(Term.dim("Keep Parallex.app running so it knows which copy you used last; otherwise you'll be asked."))
        }
    }

    struct Disable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn link routing off and restore the apps' own handlers.")

        mutating func run() async throws {
            try await LinkRouting.disable()
            print("\(Term.green("✓")) Link routing is off.")
        }
    }
}
