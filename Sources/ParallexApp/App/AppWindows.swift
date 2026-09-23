import AppKit
import SwiftUI

/// Opens Parallex's windows from anywhere — a notification, the updater,
/// the app delegate — not only from inside a SwiftUI view.
@MainActor
final class AppWindows {
    /// SwiftUI's window opener, handed over by the first scene that appears
    /// (scene windows can only be reopened through it once closed).
    static var openScene: OpenWindowAction?

    private var panels: [String: NSWindow] = [:]
    private let model: AppModel
    private let updater: Updater

    init(model: AppModel, updater: Updater) {
        self.model = model
        self.updater = updater
    }

    /// Bring up the main window, optionally on one instance.
    func showMain(selecting slug: String? = nil) {
        if let slug {
            model.selection = slug
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let window = NSApp.windows.first(where: AppDelegate.isMainWindow), window.isVisible {
            window.makeKeyAndOrderFront(nil)
        } else {
            Self.openScene?(id: SceneID.main)
        }
    }

    func showWhatsNew() {
        present(id: "whats-new", title: "What's New") { [weak self] in
            WhatsNewView { self?.close("whats-new") }
        }
    }

    func showUpdate() {
        let updater = updater
        present(id: "update", title: "Software Update") { [weak self] in
            UpdateView { self?.close("update") }.environment(updater)
        }
    }

    func close(_ id: String) {
        panels[id]?.close()
    }

    /// A small, centered, title-less window hosting SwiftUI content; reused
    /// if it's already open.
    private func present<Content: View>(id: String, title: String, @ViewBuilder content: () -> Content) {
        NSApp.activate()
        if let window = panels[id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("parallex-\(id)")
        window.contentViewController = NSHostingController(rootView: content().environment(model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        panels[id] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.panels[id] = nil }
        }
    }
}

/// Hands SwiftUI's window opener to `AppWindows` when a scene appears.
struct CaptureWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { AppWindows.openScene = openWindow }
    }
}

extension View {
    func capturesWindowOpener() -> some View {
        modifier(CaptureWindowOpener())
    }
}
