// Parallex Web — a website as an app of its own. Every web instance is a
// copy of this small browser with its own identity (Dock icon, name,
// notifications, permissions) and its own website data; it reads which
// site to show from its launch environment:
//
//   PARALLEX_WEB_URL  the site (http or https)
//   PARALLEX_WEB_LOG  development only: a file it notes what it did in
//   PARALLEX_WEB_QUIET  development only: "1" keeps the window hidden and
//                     never takes focus (tests)
//   PARALLEX_WEB_BACKGROUND  development only: "1" shows the window behind
//                     others without taking focus (screenshots)
//
// What makes a website feel like an app here: its notifications become
// macOS notifications, an unread count in its title ("(3) WhatsApp")
// becomes the Dock badge, sign-in popups stay in the app, and other links
// open in your browser (or wherever Parallex Links routes them).

import AppKit
import UserNotifications
import WebKit

let quiet = ProcessInfo.processInfo.environment["PARALLEX_WEB_QUIET"] == "1"

let log: (String) -> Void = {
    guard let path = ProcessInfo.processInfo.environment["PARALLEX_WEB_LOG"] else { return { _ in } }
    return { line in
        let data = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}()

/// What Safari says it is: some sites (WhatsApp Web among them) turn
/// away a web view that doesn't look like a current browser.
func safariUserAgent() -> String {
    let info = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        ?? NSDictionary(contentsOfFile: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/Info.plist")
    let version = info?["CFBundleShortVersionString"] as? String ?? "18.0"
    return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
}

/// The unread count a site puts in its title: "(3) WhatsApp",
/// "Inbox (12) - Gmail". Nil when there isn't one.
func unreadCount(in title: String) -> Int? {
    guard let open = title.firstIndex(of: "(") else { return nil }
    let rest = title[title.index(after: open)...]
    guard let close = rest.firstIndex(of: ")") else { return nil }
    let inside = rest[..<close].trimmingCharacters(in: CharacterSet(charactersIn: "+ "))
    return Int(inside)
}

/// The Notification API, answered by the app: WebKit views have none of
/// their own on the Mac. The page's notifications are posted as macOS
/// ones, and a click on one is passed back to the page.
let notificationBridge = """
(() => {
  if (window.__parallexNotifications) return;
  const post = (message) => window.webkit.messageHandlers.parallex.postMessage(message);
  const shown = {};
  class ParallexNotification extends EventTarget {
    static get permission() { return "granted"; }
    static requestPermission(callback) {
      if (typeof callback === "function") callback("granted");
      return Promise.resolve("granted");
    }
    constructor(title, options = {}) {
      super();
      this.title = String(title);
      this.body = options.body ? String(options.body) : "";
      this.tag = options.tag ? String(options.tag) : "";
      this.onclick = null;
      this.onclose = null;
      this.id = Math.random().toString(36).slice(2);
      shown[this.id] = this;
      post({ type: "notify", id: this.id, title: this.title, body: this.body, tag: this.tag });
    }
    close() { post({ type: "close", id: this.id }); }
  }
  window.__parallexClicked = (id) => {
    const notification = shown[id];
    if (!notification) return;
    const event = new Event("click");
    if (typeof notification.onclick === "function") notification.onclick(event);
    notification.dispatchEvent(event);
  };
  Object.defineProperty(window, "Notification", { value: ParallexNotification, configurable: true, writable: true });
  window.__parallexNotifications = true;
})();
"""

@MainActor
final class WebApp: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate,
    WKScriptMessageHandler, WKDownloadDelegate, UNUserNotificationCenterDelegate {
    let home: URL
    var window: NSWindow!
    var webView: WKWebView!
    var popups: [NSWindow] = []
    var catchers: [LinkCatcher] = []
    var titleObservation: NSKeyValueObservation?
    var notificationsAllowed: Bool?
    var lastHandoff = Date.distantPast

    init(home: URL) {
        self.home = home
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()
        UNUserNotificationCenter.current().delegate = self

        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.addUserScript(
            WKUserScript(source: notificationBridge, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        configuration.userContentController.add(self, name: "parallex")
        webView = makeWebView(configuration)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = appName
        window.contentView = webView
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ParallexWebWindow")
        if !window.setFrameUsingName("ParallexWebWindow") {
            window.center()
        }
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.titleChanged(view.title ?? "") }
        }
        webView.load(URLRequest(url: home))
        if ProcessInfo.processInfo.environment["PARALLEX_WEB_BACKGROUND"] == "1" {
            // Development: shown behind whatever you're using, never taking focus.
            window.orderBack(nil)
        } else if !quiet {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    func makeWebView(_ configuration: WKWebViewConfiguration) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = safariUserAgent()
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.navigationDelegate = self
        view.uiDelegate = self
        view.isInspectable = true
        return view
    }

    // Closing the window keeps the site running (for its notifications);
    // clicking the Dock icon brings it back.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        window.orderOut(nil)
        return false
    }

    /// A popup closed with its close button goes for good.
    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed !== window else { return }
        (closed.contentView as? WKWebView)?.stopLoading()
        closed.contentView = nil
        popups.removeAll { $0 === closed }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !window.isVisible {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Title and badge

    func titleChanged(_ title: String) {
        if !title.isEmpty {
            window.title = title
        }
        let count = unreadCount(in: title)
        let label = count.map { $0 > 0 ? String($0) : nil } ?? nil
        if NSApp.dockTile.badgeLabel != label {
            NSApp.dockTile.badgeLabel = label
            log("badge \(label ?? "none")")
        }
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView, let url = webView.url {
            log("loaded \(url.absoluteString)")
        }
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        if !["http", "https", "about", "blob", "data", "javascript"].contains(scheme) {
            decisionHandler(.cancel)
            handOff(url, scheme: scheme, fromMainFrame: navigationAction.sourceFrame.isMainFrame)
            return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    /// A new window: a sign-in popup (it asks for a size) stays in the app,
    /// so the page that opened it can hear back; any other link goes to
    /// your browser.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let url = navigationAction.request.url
        let isPopup = windowFeatures.width != nil || windowFeatures.height != nil
        if !isPopup, let url, url.scheme == "http" || url.scheme == "https" {
            openElsewhere(url)
            return nil
        }
        if !isPopup {
            // A blank window the page fills in afterwards: catch where it goes.
            let catcher = LinkCatcher(configuration: configuration) { [weak self] caught, catcher in
                self?.openElsewhere(caught)
                self?.catchers.removeAll { $0 === catcher }
            }
            catchers.append(catcher)
            return catcher.webView
        }
        let popup = makeWebView(configuration)
        let frame = NSRect(
            x: 0, y: 0,
            width: CGFloat(windowFeatures.width?.doubleValue ?? 520),
            height: CGFloat(windowFeatures.height?.doubleValue ?? 680)
        )
        let popupWindow = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        popupWindow.contentView = popup
        popupWindow.isReleasedWhenClosed = false
        popupWindow.delegate = self
        popupWindow.center()
        popupWindow.makeKeyAndOrderFront(nil)
        popups.append(popupWindow)
        log("popup \(url?.absoluteString ?? "")")
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        for popup in popups where popup.contentView === webView {
            popup.close()
        }
        popups.removeAll { $0.contentView === webView }
    }

    /// A web link for your browser. Only while you're using the app, and
    /// not in a burst: a page in the background can't open tabs for you.
    func openElsewhere(_ url: URL) {
        log("external \(url.absoluteString)")
        guard !quiet else { return }
        guard NSApp.isActive, Date().timeIntervalSince(lastHandoff) > 1 else {
            log("held back \(url.absoluteString)")
            return
        }
        lastHandoff = Date()
        NSWorkspace.shared.open(url)
    }

    /// Links that belong to other apps: mail, calls, meetings. Never files,
    /// network shares or system settings, and never from an embedded frame
    /// (an ad, say). Anything unfamiliar asks first.
    func handOff(_ url: URL, scheme: String, fromMainFrame: Bool) {
        guard fromMainFrame, !Self.neverHandedOff.contains(scheme), !scheme.hasPrefix("x-apple") else {
            log("blocked \(scheme):")
            return
        }
        if Self.otherApps.contains(scheme) {
            openElsewhere(url)
            return
        }
        guard !quiet, NSApp.isActive else {
            log("blocked \(scheme):")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Open this link in another app?"
        alert.informativeText = "\(home.host ?? "The site") wants to open a “\(scheme):” link."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            openElsewhere(url)
        }
    }

    static let otherApps: Set<String> = [
        "mailto", "tel", "sms", "facetime", "facetime-audio", "maps", "webcal",
        "zoommtg", "zoomus", "msteams", "ms-teams", "slack", "discord", "tg", "whatsapp",
        "webex", "wbx", "skype", "spotify", "itms-apps", "macappstore", "figma", "linear", "notion",
    ]

    static let neverHandedOff: Set<String> = [
        "file", "smb", "afp", "nfs", "cifs", "ftp", "ftps", "sftp", "vnc", "ssh", "telnet",
        "applescript", "help", "shortcuts", "parallex",
    ]

    /// Whether `host` belongs to the site this app is for (its own host, or
    /// another part of the same domain, like teams.microsoft.com and
    /// login.microsoft.com).
    func isHomeSite(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), let homeHost = home.host?.lowercased() else { return false }
        if host == homeHost { return true }
        let labels = homeHost.split(separator: ".")
        guard labels.count >= 3 else { return host.hasSuffix("." + homeHost) }
        let parent = labels.dropFirst().joined(separator: ".")
        // "co.uk" and "com.au" aren't a site.
        guard (labels.dropFirst().first?.count ?? 0) > 3 else { return false }
        return host == parent || host.hasSuffix("." + parent)
    }

    // MARK: Page dialogs, uploads, camera and microphone

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }

    /// Calls: the site itself gets the camera and microphone (macOS asks
    /// you once, as it does for any app); anything else, like an embedded
    /// frame from another site, has to ask.
    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        decisionHandler(frame.isMainFrame && isHomeSite(origin.host) ? .grant : .prompt)
    }

    // MARK: Downloads

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
        completionHandler: @escaping @MainActor (URL?) -> Void
    ) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = (suggestedFilename as NSString).lastPathComponent
        var destination = downloads.appendingPathComponent(name.isEmpty ? "download" : name)
        var index = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            destination = downloads.appendingPathComponent(ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
            index += 1
        }
        log("download \(destination.lastPathComponent)")
        completionHandler(destination)
    }

    // MARK: Notifications

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only the page itself (what the window shows) speaks for the app,
        // not a frame embedded in it. Services move between their domains
        // (office.com, office365.com), so its host isn't checked.
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], let type = body["type"] as? String,
              let id = body["id"] as? String, id.count <= 200
        else { return }
        switch type {
        case "notify":
            let title = body["title"] as? String ?? ""
            log("notify \(title)")
            post(id: id, title: title, body: body["body"] as? String ?? "", tag: body["tag"] as? String ?? "")
        case "close":
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        default:
            break
        }
    }

    func post(id: String, title: String, body: String, tag: String) {
        guard !quiet else { return }
        if notificationsAllowed == true {
            deliver(id: id, title: title, body: body, tag: tag)
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in
                self.notificationsAllowed = granted
                if granted {
                    self.deliver(id: id, title: title, body: body, tag: tag)
                }
            }
        }
    }

    func deliver(id: String, title: String, body: String, tag: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["id": id]
        if !tag.isEmpty {
            content.threadIdentifier = tag
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Called on UserNotifications' own queue: no AppKit here. The page
        // decides when to notify (sites stay quiet while you're looking).
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.content.userInfo["id"] as? String ?? ""
        // Called on UserNotifications' own queue, not the main thread.
        Task { @MainActor in
            self.window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            // The id travels as an argument, never spliced into the script.
            _ = try? await self.webView.callAsyncJavaScript(
                "if (window.__parallexClicked) window.__parallexClicked(id)",
                arguments: ["id": id], contentWorld: .page
            )
        }
        completionHandler()
    }

    // MARK: Menu

    @objc func reload(_ sender: Any?) { webView.reload() }
    @objc func goBack(_ sender: Any?) { webView.goBack() }
    @objc func goForward(_ sender: Any?) { webView.goForward() }
    @objc func goHome(_ sender: Any?) { webView.load(URLRequest(url: home)) }
    @objc func zoomIn(_ sender: Any?) { webView.pageZoom = min(webView.pageZoom + 0.1, 3) }
    @objc func zoomOut(_ sender: Any?) { webView.pageZoom = max(webView.pageZoom - 0.1, 0.5) }
    @objc func actualSize(_ sender: Any?) { webView.pageZoom = 1 }
    @objc func copyLink(_ sender: Any?) {
        guard let url = webView.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
    @objc func openInBrowser(_ sender: Any?) {
        if let url = webView.url { NSWorkspace.shared.open(url) }
    }
    @objc func showWindow(_ sender: Any?) { window.makeKeyAndOrderFront(nil) }

    /// The instance's name: copies keep Parallex Web's CFBundleName (apps
    /// use it internally) and carry theirs as the display name.
    var appName: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? "Web"
    }

    func makeMenu() -> NSMenu {
        let name = appName
        let menu = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            items.forEach(sub.addItem)
            item.submenu = sub
            menu.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers
            return entry
        }
        submenu(name, [
            item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Copy Link", #selector(copyLink(_:)), "c", [.command, .shift]),
        ])
        submenu("View", [
            item("Reload", #selector(reload(_:)), "r"),
            .separator(),
            item("Actual Size", #selector(actualSize(_:)), "0"),
            item("Zoom In", #selector(zoomIn(_:)), "+"),
            item("Zoom Out", #selector(zoomOut(_:)), "-"),
            .separator(),
            item("Open in Browser", #selector(openInBrowser(_:)), "o", [.command, .shift]),
        ])
        submenu("History", [
            item("Back", #selector(goBack(_:)), "["),
            item("Forward", #selector(goForward(_:)), "]"),
            item("Home", #selector(goHome(_:)), "h", [.command, .shift]),
        ])
        submenu("Window", [
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item(name, #selector(showWindow(_:)), "0", [.command, .option]),
        ])
        return menu
    }
}

/// Takes the first place a blank new window goes, then gets out of the way.
@MainActor
final class LinkCatcher: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private let caught: (URL, LinkCatcher) -> Void
    private var done = false

    init(configuration: WKWebViewConfiguration, caught: @escaping (URL, LinkCatcher) -> Void) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.caught = caught
        super.init()
        webView.navigationDelegate = self
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https", !done else {
            decisionHandler(.allow)
            return
        }
        done = true
        decisionHandler(.cancel)
        caught(url, self)
    }
}

// MARK: - Main

guard let text = ProcessInfo.processInfo.environment["PARALLEX_WEB_URL"],
      let home = URL(string: text), ["http", "https"].contains(home.scheme?.lowercased() ?? "")
else {
    let alert = NSAlert()
    alert.messageText = "This web instance has no website to show."
    alert.informativeText = "Open Parallex and repair it."
    alert.runModal()
    exit(1)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { WebApp(home: home) }
app.delegate = delegate
// Hidden from the Dock (Parallex's setting for the copy): no Dock icon.
let hidden = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool ?? false
app.setActivationPolicy(hidden ? .accessory : .regular)
app.run()
