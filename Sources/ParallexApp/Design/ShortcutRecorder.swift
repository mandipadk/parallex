import AppKit
import Carbon.HIToolbox
import ParallexCore
import SwiftUI

/// Records a global keyboard shortcut. Click to start, press the keys; Esc
/// cancels, Delete clears. A combination that can't be used is explained in
/// place and not saved.
struct ShortcutRecorder: View {
    @Binding var shortcut: KeyShortcut?
    /// Why a recorded shortcut can't be used, or nil when it can.
    var conflict: (KeyShortcut) -> String?

    @Environment(AppModel.self) private var model
    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: String?
    @State private var live: KeyShortcut.Modifiers = []
    /// When a click ended recording — so a click on the recorder itself
    /// cancels instead of immediately starting again.
    @State private var clickedAwayAt: Date?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: toggleRecording) {
                    HStack(spacing: 6) {
                        if recording {
                            Circle().fill(Theme.accent).frame(width: 6, height: 6)
                                .phaseAnimator([1.0, 0.35]) { dot, opacity in dot.opacity(opacity) } animation: { _ in
                                    .easeInOut(duration: 0.7)
                                }
                            Text(live.isEmpty ? "Type shortcut" : KeyShortcut(keyCode: 0, modifiers: live, key: "").displayString)
                                .foregroundStyle(live.isEmpty ? .secondary : .primary)
                        } else if let shortcut {
                            Text(shortcut.displayString)
                                .fontWeight(.medium)
                        } else {
                            Text("Record Shortcut")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 12.5, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 118)
                    .frame(height: 26)
                    .padding(.horizontal, 10)
                    .background(Theme.subtleFill, in: .capsule)
                    .overlay(
                        Capsule().strokeBorder(recording ? Theme.accent : Theme.hairline, lineWidth: recording ? 1.5 : 1)
                    )
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(shortcut.map { "Shortcut \($0.displayString)" } ?? "Record shortcut")

                if shortcut != nil, !recording {
                    Button {
                        withAnimation(Theme.Motion.snappy) { shortcut = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove shortcut")
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            if let problem {
                Text(problem)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.attention)
                    .multilineTextAlignment(.trailing)
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.snappy, value: recording)
        .animation(Theme.Motion.snappy, value: problem)
        .onDisappear(perform: stop)
        // Key events only reach the recorder while Parallex is active; leaving
        // it (⌘Tab, another window) ends recording rather than leaving
        // every instance shortcut switched off.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            stop()
        }
    }

    private func toggleRecording() {
        if let clickedAwayAt, Date().timeIntervalSince(clickedAwayAt) < 0.5 {
            self.clickedAwayAt = nil
            return
        }
        recording ? stop() : start()
    }

    private func start() {
        problem = nil
        live = []
        recording = true
        model.recordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { event in
            handle(event)
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        live = []
        if recording {
            recording = false
            model.recordingShortcut = false
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // Clicking anywhere else ends recording (and still clicks).
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            clickedAwayAt = Date()
            stop()
            return event
        }
        let modifiers = Self.modifiers(event.modifierFlags)
        if event.type == .flagsChanged {
            live = modifiers
            return nil
        }
        switch Int(event.keyCode) {
        case kVK_Escape where modifiers.isEmpty:
            stop()
            return nil
        case kVK_Delete where modifiers.isEmpty, kVK_ForwardDelete where modifiers.isEmpty:
            shortcut = nil
            stop()
            return nil
        default:
            break
        }
        let recorded = KeyShortcut(keyCode: event.keyCode, modifiers: modifiers, key: Self.keyLabel(event))
        if let reason = conflict(recorded) {
            problem = reason
            NSSound.beep()
        } else {
            problem = nil
            shortcut = recorded
            stop()
        }
        return nil
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyShortcut.Modifiers {
        var result: KeyShortcut.Modifiers = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    /// The key as the current keyboard layout prints it without modifiers.
    static func keyLabel(_ event: NSEvent) -> String {
        if let symbol = KeyShortcut.symbol(forKeyCode: event.keyCode) {
            return symbol
        }
        let plain = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "?"
        return plain.uppercased()
    }
}
