import AppKit
import ParallexCore

/// Draws a colored border and a name tag over every window of a running
/// instance, so a clone is recognizable at a glance even though macOS shows
/// it under the original app's name and icon.
///
/// Needs no special permission: the window list reports each window's owner
/// PID and bounds without Screen Recording access (only titles need it).
/// Overlays are click-through, ordered directly above their window, and
/// follow it on a short timer.
@MainActor
final class WindowTagger {
    struct Target: Equatable {
        let pid: pid_t
        let name: String
        let color: NSColor
    }

    var showsNameTag = true {
        didSet { overlays.values.forEach { $0.tagView.showsName = showsNameTag } }
    }

    private var targets: [pid_t: Target] = [:]
    private var overlays: [CGWindowID: Overlay] = [:]
    private var timer: Timer?

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        overlays.values.forEach { $0.panel.orderOut(nil) }
        overlays.removeAll()
    }

    func setTargets(_ newTargets: [Target]) {
        targets = Dictionary(newTargets.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func tick() {
        guard !targets.isEmpty else {
            if !overlays.isEmpty {
                overlays.values.forEach { $0.panel.orderOut(nil) }
                overlays.removeAll()
            }
            return
        }
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return
        }
        let ownWindowNumbers = Set(overlays.values.map { CGWindowID($0.panel.windowNumber) })
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var seen = Set<CGWindowID>()
        // Front-to-back positions, plus what's needed to recognize another
        // Parallex process's outline (e.g. a second copy of the app): same
        // owner name prefix, a different process, and exactly the frame of
        // the window it outlines. Parallex's own regular windows never count.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var position: [CGWindowID: Int] = [:]
        var windowInfo: [(id: CGWindowID, isOurs: Bool, foreignParallex: Bool, bounds: CGRect)] = []
        for (index, info) in list.enumerated() {
            let id = info[kCGWindowNumber as String] as? CGWindowID ?? 0
            position[id] = index
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                .flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
            windowInfo.append((id, ownWindowNumbers.contains(id), pid != ownPID && owner.hasPrefix("Parallex"), bounds))
        }

        for info in list {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  !ownWindowNumbers.contains(id),
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let target = targets[pid],
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 120, bounds.height >= 80
            else {
                continue
            }
            seen.insert(id)
            // Window-list coordinates are top-left based on the primary
            // screen; AppKit's are bottom-left.
            let frame = NSRect(
                x: bounds.minX,
                y: primaryHeight - bounds.maxY,
                width: bounds.width,
                height: bounds.height
            )
            let overlay = overlays[id] ?? {
                let created = Overlay(showsName: showsNameTag)
                overlays[id] = created
                return created
            }()
            overlay.update(frame: frame, target: target)
            // Correctly placed: in front of its window with nothing but
            // overlays in between. Reordering only when that's not true
            // keeps two outline sources from leapfrogging each other.
            let placed: Bool = {
                guard overlay.panel.isVisible,
                      let mine = position[CGWindowID(overlay.panel.windowNumber)],
                      let theirs = position[id],
                      mine < theirs
                else { return false }
                return (mine + 1..<theirs).allSatisfy { index in
                    let between = windowInfo[index]
                    return between.isOurs || (between.foreignParallex && between.bounds == bounds)
                }
            }()
            if !placed {
                overlay.panel.order(.above, relativeTo: Int(id))
            }
        }

        for (id, overlay) in overlays where !seen.contains(id) {
            overlay.panel.orderOut(nil)
            overlays[id] = nil
        }
    }

    /// One click-through overlay window.
    @MainActor
    private final class Overlay {
        let panel: NSPanel
        let tagView: TagView

        init(showsName: Bool) {
            panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
            tagView = TagView()
            tagView.showsName = showsName
            panel.contentView = tagView
        }

        func update(frame: NSRect, target: Target) {
            if panel.frame != frame {
                panel.setFrame(frame, display: false)
            }
            if tagView.name != target.name || tagView.color != target.color {
                tagView.name = target.name
                tagView.color = target.color
                tagView.needsDisplay = true
            }
        }
    }

    /// Border plus a small name pill at the top center.
    private final class TagView: NSView {
        var name = ""
        var color = NSColor.systemIndigo
        var showsName = true {
            didSet { needsDisplay = true }
        }

        override func draw(_ dirtyRect: NSRect) {
            let lineWidth: CGFloat = 3
            let border = NSBezierPath(
                roundedRect: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                xRadius: 10, yRadius: 10
            )
            border.lineWidth = lineWidth
            color.withAlphaComponent(0.9).setStroke()
            border.stroke()

            guard showsName, !name.isEmpty else { return }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let text = NSAttributedString(string: name, attributes: attributes)
            let size = text.size()
            let pill = NSRect(
                x: bounds.midX - size.width / 2 - 8,
                y: bounds.maxY - size.height - 4,
                width: size.width + 16,
                height: size.height + 4
            )
            let path = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
            color.withAlphaComponent(0.92).setFill()
            path.fill()
            text.draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + 2))
        }
    }
}
