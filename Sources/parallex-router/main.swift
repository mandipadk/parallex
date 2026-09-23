// Parallex Links — the background app that receives sign-in links for apps
// with several running copies and passes each link to the right copy.
// Parallex generates its bundle (declaring the routed schemes) and makes it
// the default handler; see `LinkRouting`.

import AppKit
import ParallexCore

@MainActor
final class RouterDelegate: NSObject, NSApplicationDelegate {
    private var handledAny = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched without a link (e.g. opened by hand): nothing to do.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.handledAny == false {
                NSApp.terminate(nil)
            }
        }
    }

    private var pendingOpens = 0

    func application(_ application: NSApplication, open urls: [URL]) {
        handledAny = true
        for url in urls {
            route(url)
        }
        finishIfIdle()
    }

    private func finishIfIdle() {
        if pendingOpens == 0 {
            NSApp.terminate(nil)
        }
    }

    private func route(_ url: URL) {
        let config = LinkRouting.loadConfiguration()
        guard let scheme = url.scheme?.lowercased() else { return }
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
