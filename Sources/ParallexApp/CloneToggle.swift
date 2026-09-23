import SwiftUI
import ParallexCore

/// "Own identity" (clone mode) toggle with what to expect from the copy.
struct CloneToggle: View {
    @Binding var isOn: Bool
    let assessment: AppCloner.Assessment

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Own identity (copy the app)")
                Text(assessment.possible
                     ? "Its own Dock icon, name, notifications, and permissions — and, for App Store apps, its own data container."
                     : assessment.notes.first ?? "Not possible for this app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!assessment.possible)
        if isOn && assessment.possible {
            ForEach(assessment.notes.dropFirst(), id: \.self) { note in
                Label {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "info.circle").foregroundStyle(.secondary).imageScale(.small)
                }
            }
        }
    }
}
