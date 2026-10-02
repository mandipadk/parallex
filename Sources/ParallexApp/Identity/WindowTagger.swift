import AppKit
import ParallexCore

/// Draws a colored border and a name tag over every window of a running
/// instance, so a clone is recognizable at a glance even though macOS shows
/// it under the original app's name and icon.
///
/// Needs no special permission: the window list reports each window's owner
/// PID and bounds without Screen Recording access (only titles need it).
/// Overlays are click-through, ordered directly above their window, and
/// follow it: a scan of the window list a few times a second finds windows
/// and keeps the order right, and while a window moves its outline follows
/// at display rate, asking about just the outlined windows.
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
    /// Runs while an outlined window is moving or resizing.
    private var followTimer: Timer?
    private var lastMove = Date.distantPast

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        // On the main run loop, so already on the main actor: no hop (a
        // Task here added a frame of lag to every move).
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stopFollowing()
        overlays.values.forEach { $0.panel.orderOut(nil) }
        overlays.removeAll()
    }

    private func startFollowing() {
        lastMove = Date()
        guard followTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
    }

    /// Moves outlines to where their windows are now, asking the window
    /// server about just those windows. Stops once nothing has moved for a
    /// moment; the scan picks moving up again.
    private func follow() {
        guard !overlays.isEmpty else { return stopFollowing() }
        let ids = Array(overlays.keys)
        let pointers: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        let array = pointers.withUnsafeBufferPointer { buffer in
            CFArrayCreate(nil, UnsafeMutablePointer(mutating: buffer.baseAddress), buffer.count, nil)
        }
        guard let array,
              let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]]
        else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var moved = false
        for info in list {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let overlay = overlays[id],
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            moved = overlay.move(to: Self.appKitFrame(bounds, primaryHeight: primaryHeight)) || moved
        }
        if moved {
            lastMove = Date()
        } else if Date().timeIntervalSince(lastMove) > 0.5 {
            stopFollowing()
        }
    }

    /// Window-list coordinates are top-left based on the primary screen;
    /// AppKit's are bottom-left.
    private static func appKitFrame(_ bounds: CGRect, primaryHeight: CGFloat) -> NSRect {
        NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
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
            let frame = Self.appKitFrame(bounds, primaryHeight: primaryHeight)
            let existing = overlays[id]
            let overlay = existing ?? {
                let created = Overlay(showsName: showsNameTag)
                overlays[id] = created
                return created
            }()
            overlay.update(target: target)
            if overlay.move(to: frame), existing != nil {
                startFollowing()
            }
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

        /// Whether the outline had to move.
        @discardableResult
        func move(to frame: NSRect) -> Bool {
            guard panel.frame != frame else { return false }
            panel.setFrame(frame, display: false)
            return true
        }

        func update(target: Target) {
            if tagView.name != target.name || tagView.color != target.color {
                tagView.name = target.name
                tagView.color = target.color
            }
        }
    }

    /// Border plus a small name pill at the top center, as layers: they
    /// resize with the window without being drawn again (drawn content
    /// that wasn't redrawn after a resize left the border broken).
    private final class TagView: NSView {
        private let border = CALayer()
        private let pill = CALayer()
        private let label = CATextLayer()
        private static let lineWidth: CGFloat = 3

        var name = "" { didSet { layoutTag() } }
        var color = NSColor.systemIndigo { didSet { applyColor() } }
        var showsName = true { didSet { layoutTag() } }

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layerContentsRedrawPolicy = .never
            // Outlines jump to where the window is, never animate there.
            let still: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(),
                                             "contents": NSNull(), "hidden": NSNull(), "string": NSNull()]
            for layer in [border, pill, label] as [CALayer] {
                layer.actions = still
            }
            border.borderWidth = Self.lineWidth
            border.cornerRadius = 10
            label.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            label.fontSize = 10.5
            label.foregroundColor = NSColor.white.cgColor
            label.alignmentMode = .center
            layer?.addSublayer(border)
            layer?.addSublayer(pill)
            pill.addSublayer(label)
            applyColor()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            label.contentsScale = window?.backingScaleFactor ?? 2
        }

        // Laid out right here, inside the window's resize, so the outline is
        // never a frame behind it. (Layer autoresizing from the overlay's
        // first, empty size gives the tag an invalid position.)
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            guard newSize.width > 0, newSize.height > 0 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            border.frame = bounds.insetBy(dx: Self.lineWidth / 2, dy: Self.lineWidth / 2)
            CATransaction.commit()
            layoutTag()
        }

        private func applyColor() {
            border.borderColor = color.withAlphaComponent(0.9).cgColor
            pill.backgroundColor = color.withAlphaComponent(0.92).cgColor
        }

        private func layoutTag() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            pill.isHidden = !showsName || name.isEmpty
            guard !pill.isHidden, bounds.width > 0, bounds.height > 0 else { return }
            let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            let size = (name as NSString).size(withAttributes: [.font: font])
            let height = ceil(size.height) + 4
            let width = ceil(size.width) + 16
            // Layer coordinates start at the bottom left: against the top edge.
            pill.frame = NSRect(x: (bounds.width - width) / 2, y: bounds.height - height, width: width, height: height)
            pill.cornerRadius = height / 2
            label.string = name
            label.frame = NSRect(x: 0, y: 0, width: width, height: height - 2)
            label.contentsScale = window?.backingScaleFactor ?? 2
        }
    }
}
