import AppKit
import ParallexCore

/// Services › Open in a Clean Window: the selected link opens in a website
/// instance of its own, a throwaway that quits when its window closes and
/// that Parallex then trashes (see `CleanWindow`). It starts only from the
/// Services menu; at worst another app could ask for one, which makes a
/// throwaway and nothing more.
@MainActor
final class CleanWindowService: NSObject {
    private let model: AppModel
    private let windows: AppWindows
    /// One at a time, so two quick requests don't pick the same name.
    private var last: Task<Void, Never>?

    init(model: AppModel, windows: AppWindows) {
        self.model = model
        self.windows = windows
    }

    @objc func openInCleanWindow(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        let candidates = urls.map(\.absoluteString) + [pasteboard.string(forType: .string)].compactMap { $0 }
        guard let link = CleanWindow.link(in: candidates) else {
            let message = "Select a web address (http or https) to open it in a clean window."
            error.pointee = message as NSString
            windows.showMain()
            model.errorMessage = message
            return
        }
        let previous = last
        last = Task {
            await previous?.value
            await open(link)
        }
    }

    private func open(_ link: URL) async {
        let color = IconBuilder.palette[0]
        var request = CreateRequest(appReference: "", name: nil, badgeColorHex: color)
        // Not a name already used by an instance, or by an app where the
        // new one goes.
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: request.outputDirectory.path)) ?? []
        let taken = Set(model.entries.map(\.manifest.name))
            .union(apps.filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) })
        let name = CleanWindow.freeName(taken: taken)
        request.name = name
        request.webURL = link.absoluteString
        request.throwaway = true
        // A monogram, not the site's icon: nothing is fetched before you open it.
        request.customIcon = WebIcon.monogram(for: name, colorHex: color)
        do {
            let result = try await model.create(request, select: false)
            if let entry = model.entries.first(where: { $0.id == result.manifest.slug }) {
                model.activate(entry)
            }
        } catch {
            windows.showMain()
            model.errorMessage = "The clean window couldn't be made: \(error)"
        }
    }
}
