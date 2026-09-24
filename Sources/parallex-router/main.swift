// Parallex Links — the background app that receives links and passes each to
// the right place: sign-in links to the copy of the app that asked for them,
// and (when web routing is on) web links to the browser of the instance they
// came from. Parallex generates its bundle (declaring the routed schemes) and
// makes it the default handler; see `LinkRouting` and `WebRouting`.

import AppKit
import ParallexCore

@MainActor
final class RouterDelegate: NSObject, NSApplicationDelegate {
    private var handledAny = false
    private var pendingOpens = 0

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The raw event, not application(_:open:): it says who sent the link.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched without a link (e.g. opened by hand): nothing to do.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.handledAny == false {
                self?.finishIfIdle()
            }
        }
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text)
        else { return }
        let sender = event.attributeDescriptor(forKeyword: keySenderPIDAttr).map { pid_t($0.int32Value) }
        handledAny = true
        route(url, sender: sender.flatMap { $0 > 0 ? $0 : nil })
        finishIfIdle()
    }

    /// Web pages opened as files go to your usual browser.
    func application(_ application: NSApplication, open urls: [URL]) {
        handledAny = true
        for url in urls {
            if url.isFileURL {
                openWeb(url, target: nil)
            } else {
                route(url, sender: nil)
            }
        }
        finishIfIdle()
    }

    /// Sign-in routing is done in a moment; web routing keeps the router
    /// running, so a click doesn't wait for it to start.
    private func finishIfIdle() {
        if pendingOpens == 0, !LinkRouting.loadConfiguration().routesWeb {
            NSApp.terminate(nil)
        }
    }

    private func route(_ url: URL, sender: pid_t?) {
        guard let scheme = url.scheme?.lowercased() else { return }
        if WebRouting.schemes.contains(scheme) {
            routeWeb(url, sender: sender)
        } else {
            routeSignIn(url, scheme: scheme)
        }
    }

    private func routeWeb(_ url: URL, sender: pid_t?) {
        let config = LinkRouting.loadConfiguration()
        let manifests = InstanceStore.loadAll()
        var running: [String: pid_t] = [:]
        for manifest in manifests {
            if let pid = Running.processID(of: manifest) {
                running[manifest.slug] = pid
            }
        }
        var target = WebRouting.target(
            for: url,
            sender: sender,
            rules: config.webRules ?? [],
            workspaces: WorkspaceStore.load(),
            instanceOwning: { WebRouting.instance(owning: $0, running: running) }
        )
        // Never back to where it came from (a loop, if that app sends web
        // links out again).
        if case .instance(let slug) = target, let sender, WebRouting.instance(owning: sender, running: running) == slug {
            target = nil
        }
        openWeb(url, target: target, config: config, manifests: manifests, running: running)
    }

    private func openWeb(
        _ url: URL, target: WebLinkTarget?,
        config: LinkRouting.Configuration = LinkRouting.loadConfiguration(),
        manifests: [InstanceManifest] = InstanceStore.loadAll(),
        running: [String: pid_t] = [:]
    ) {
        pendingOpens += 1
        WebRouting.open(
            url, in: target,
            fallback: config.previousBrowser.map(URL.init(fileURLWithPath:)),
            manifests: manifests,
            running: running
        ) {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pendingOpens -= 1
                    self.finishIfIdle()
                }
            }
        }
    }

    private func routeSignIn(_ url: URL, scheme: String) {
        let config = LinkRouting.loadConfiguration()
        let candidates = LinkRouting.candidates(for: scheme, manifests: InstanceStore.loadAll())
        let chosen: LinkRouting.Candidate?
        switch candidates.count {
        case 0:
            // No copy running: open it normally, and stay alive until the
            // request has gone through.
            pendingOpens += 1
            LinkRouting.openNormally(url, config: config) {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.pendingOpens -= 1
                        self.finishIfIdle()
                    }
                }
            }
            return
        case 1:
            chosen = candidates[0]
        default:
            if !config.alwaysAsk, let recent = LinkRouting.mostRecent(candidates) {
                chosen = recent
            } else {
                chosen = ask(url: url, candidates: candidates)
            }
        }
        guard let chosen else { return }
        do {
            try LinkRouting.deliver(url, to: chosen.pid)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't open the link in “\(chosen.name)”"
            alert.informativeText = "\(error)"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func ask(url: URL, candidates: [LinkRouting.Candidate]) -> LinkRouting.Candidate? {
        let alert = NSAlert()
        alert.messageText = "Which copy should open this link?"
        alert.informativeText = "\(url.scheme ?? "")://… — several copies of the app are running."
        let options = Array(candidates.prefix(8))
        for candidate in options {
            alert.addButton(withTitle: candidate.name)
        }
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return options.indices.contains(response) ? options[response] : nil
    }
}

let app = NSApplication.shared
let delegate = RouterDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
