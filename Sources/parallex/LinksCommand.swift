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
        subcommands: [Status.self, Enable.self, Disable.self, Web.self, Rule.self],
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

    struct Web: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open web links from each instance in its workspace's browser.",
            discussion: """
            With this on, Parallex Links becomes your default browser (macOS asks you \
            to confirm). A link opened by an instance goes to the browser its \
            workspace names (`parallex workspace browser`), a site with a rule \
            (`parallex links rule`) goes where the rule says, and everything else \
            goes to the browser you had before.
            """
        )

        @Argument(help: "on, off, or status.")
        var state: String = "status"

        mutating func run() async throws {
            switch state.lowercased() {
            case "on":
                let config = try await LinkRouting.enableWeb(routerBinary: try LauncherLocator.locateRouter())
                print("\(Term.green("✓")) Web links are routed. Everything else opens in "
                    + "\(config.previousBrowser.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "your browser").")
            case "off":
                try await LinkRouting.disableWeb(routerBinary: try LauncherLocator.locateRouter())
                print("\(Term.green("✓")) Web links go straight to your browser again.")
            case "status":
                let config = LinkRouting.loadConfiguration()
                let manifests = InstanceStore.loadAll()
                let routing = WebRouting.schemes.allSatisfy(LinkRouting.isRouting)
                print("Web links: \(config.routesWeb && routing ? Term.green("routed") : config.routesWeb ? Term.yellow("on, but another browser is the default") : "off")")
                if let previous = config.previousBrowser {
                    print("  Everything else: \(URL(fileURLWithPath: previous).deletingPathExtension().lastPathComponent)")
                }
                for workspace in WorkspaceStore.load() where workspace.webLinks != nil {
                    print("  \(workspace.name): \(WebRouting.describe(workspace.webLinks, manifests: manifests))")
                }
                for rule in config.webRules ?? [] {
                    print("  \(rule.domain) → \(WebRouting.describe(rule.target, manifests: manifests))")
                }
            default:
                throw ValidationError("Use on, off, or status.")
            }
        }
    }

    struct Rule: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Always open a site in a given browser, profile or instance.",
            subcommands: [Add.self, Remove.self, List.self],
            defaultSubcommand: List.self
        )

        struct Add: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Add or change a site rule.")
            @Argument(help: "The site, like northwind.com (its subdomains too).")
            var site: String
            @Argument(help: "An instance's name, <Browser>/<Profile> (Chrome/Work), or a browser's name.")
            var target: String

            mutating func run() throws {
                let domain = WebRouting.normalizedDomain(site)
                guard domain.contains("."), !domain.contains(" ") else {
                    throw ValidationError("Give a site like northwind.com.")
                }
                let browsers = WebRouting.browsers()
                let manifests = InstanceStore.loadAll()
                guard let resolved = try WebRouting.resolveTarget(
                    target, manifests: manifests, browsers: browsers, profiles: WebRouting.profiles(in: browsers)
                ) else {
                    throw ValidationError("A rule needs somewhere to send the site; to remove one, use `parallex links rule remove`.")
                }
                var rules = (LinkRouting.loadConfiguration().webRules ?? []).filter { WebRouting.normalizedDomain($0.domain) != domain }
                rules.append(WebLinkRule(domain: domain, target: resolved))
                try LinkRouting.setWebRules(rules.sorted { $0.domain < $1.domain })
                print("\(Term.green("✓")) \(domain) → \(WebRouting.describe(resolved, manifests: manifests))")
                if !LinkRouting.loadConfiguration().routesWeb {
                    print(Term.dim("Turn web routing on to use it: parallex links web on"))
                }
            }
        }

        struct Remove: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Remove a site rule.")
            @Argument(help: "The site.")
            var site: String

            mutating func run() throws {
                let domain = WebRouting.normalizedDomain(site)
                let rules = LinkRouting.loadConfiguration().webRules ?? []
                guard rules.contains(where: { WebRouting.normalizedDomain($0.domain) == domain }) else {
                    throw ValidationError("There's no rule for \(domain).")
                }
                try LinkRouting.setWebRules(rules.filter { WebRouting.normalizedDomain($0.domain) != domain })
                print("\(Term.green("✓")) Removed the rule for \(domain).")
            }
        }

        struct List: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "List site rules.")

            mutating func run() throws {
                let rules = LinkRouting.loadConfiguration().webRules ?? []
                let manifests = InstanceStore.loadAll()
                if rules.isEmpty {
                    print("No site rules. Add one with: parallex links rule add northwind.com \"Chrome/Work\"")
                }
                for rule in rules {
                    print("\(rule.domain) → \(WebRouting.describe(rule.target, manifests: manifests))")
                }
            }
        }
    }
}
