import ParallexCore
import SwiftUI

/// Something's Off: a note to Parallex's maker, straight from the app. What
/// goes is shown before it goes (See What's Sent), and nothing does
/// without Send.
struct FeedbackView: View {
    var onClose: () -> Void
    /// The instance it's about, when opened from one.
    var preselected: String?
    @Environment(AppModel.self) private var model
    @State private var about: String = ""
    @State private var message = ""
    @State private var contact = ""
    @State private var showingNote = false
    @State private var sending = false
    @State private var sent = false
    @State private var failure: String?

    private var manifest: InstanceManifest? {
        model.entries.first { $0.id == about }?.manifest
    }

    private var note: Feedback.Note {
        Feedback.make(message: message, contact: contact, about: manifest)
    }

    private var contactProblem: Bool {
        let typed = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        return !typed.isEmpty && !Feedback.isValidContact(typed)
    }

    private var canSend: Bool {
        message.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 && !sending && !contactProblem
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if sent {
                thanks
            } else {
                form
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 520)
        .onAppear { about = preselected ?? "" }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Something's off?").font(.system(size: 22, weight: .bold)).tracking(-0.3)
                Text("Tell Parallex's maker what happened, in your own words. It's read by a person.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
            }
            Picker("About", selection: $about) {
                Text("Parallex in general").tag("")
                if !model.entries.isEmpty { Divider() }
                ForEach(model.entries) { entry in
                    Text(entry.manifest.name).tag(entry.id)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $message)
                    .font(Theme.Font.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 140)
                    .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: Theme.Radius.control))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.hairline))
                    .overlay(alignment: .topLeading) {
                        if message.isEmpty {
                            Text("What were you doing, and what went wrong?")
                                .font(Theme.Font.body)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                Text(manifest == nil
                    ? "Goes with it: this Parallex's version, macOS's version and your Mac's chip."
                    : "Goes with it: this Parallex's version, macOS's version and your Mac's chip, and how this instance has been doing (its kind, its app if it's a well-known one, whether it has quit at launch or found leaks). Never its name, paths or contents.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField("Your email, if you'd like a reply (optional)", text: $contact)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                if contactProblem {
                    Text("That doesn't look like an email address.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.failure)
                }
            }
            if let failure {
                Text(failure).font(Theme.Font.callout).foregroundStyle(Theme.failure)
            }
            HStack {
                Button("See What's Sent") { showingNote = true }
                    .buttonStyle(.plain)
                    .font(Theme.Font.callout.weight(.medium))
                    .foregroundStyle(Theme.accent)
                Spacer()
                Button("Cancel", action: onClose).quietAction().disabled(sending)
                Button(action: send) {
                    ZStack {
                        Text("Send").opacity(sending ? 0 : 1)
                        if sending { ProgressView().controlSize(.small) }
                    }
                    .frame(minWidth: 60)
                }
                .prominentAction()
                .keyboardShortcut(.defaultAction)
                .disabled(!canSend)
            }
        }
        .sheet(isPresented: $showingNote) { NotePreview(note: note) }
    }

    private var thanks: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Theme.accent)
            Text("Thanks, it's on its way").font(.system(size: 22, weight: .bold)).tracking(-0.3)
            Text(note.contact == nil
                ? "It'll be read. If it's about an app update breaking copies, a notice may appear in Parallex before a fix does."
                : "It'll be read, and if there's something to say back, you'll hear at \(note.contact ?? "your address").")
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done", action: onClose).prominentAction().keyboardShortcut(.defaultAction)
            }
        }
    }

    private func send() {
        let note = note
        sending = true
        failure = nil
        Task {
            do {
                try await Feedback.send(note)
                sent = true
            } catch {
                failure = "\(error)"
            }
            sending = false
        }
    }
}

/// The note exactly as it would go.
private struct NotePreview: View {
    let note: Feedback.Note
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("What's sent").font(Theme.Font.title)
            Text("The whole note, as it would go to parallex.mandip.dev.")
                .font(Theme.Font.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(String(decoding: Feedback.json(note), as: UTF8.self))
                    .font(Theme.Font.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.m)
            }
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.hairline))
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 480, height: 440)
    }
}
