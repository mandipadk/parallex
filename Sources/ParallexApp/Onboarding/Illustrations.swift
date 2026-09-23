import SwiftUI

/// A slice of the menu bar showing which instance is in front.
struct MenuBarIllustration: View {
    var color: Color = Color(hex: "#0A84FF")
    @State private var front = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: "wifi").font(.system(size: 11, weight: .semibold))
                Image(systemName: "battery.75percent").font(.system(size: 12))
                HStack(spacing: 5) {
                    if front {
                        Circle().fill(color).frame(width: 7, height: 7)
                        Text("Claude Work").font(.system(size: 11.5, weight: .medium))
                    } else {
                        ParallelMark(size: 15, split: 1, tint: .primary)
                    }
                }
                .transition(.opacity)
                Text("9:41").font(.system(size: 11.5, weight: .medium)).monospacedDigit()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(.regularMaterial, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(Self.rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 8) {
                        InstanceGlyph(iconPath: row.path, color: [color, Color(hex: "#30A46C"), Color(hex: "#D99A0B")][index], size: 18)
                        let name = row.name
                        Text(name).font(.system(size: 11.5, weight: index == 0 && front ? .semibold : .regular))
                        Spacer()
                        if index < 2 {
                            Circle().fill(Theme.running).frame(width: 5, height: 5)
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 210)
            .background(.regularMaterial, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 5)
        }
        .frame(width: 230, alignment: .trailing)
        .animation(reduceMotion ? nil : Theme.Motion.smooth, value: front)
        .task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            front = true
        }
        .accessibilityHidden(true)
    }

    /// Real apps from this Mac where possible, as instances.
    static let rows: [(name: String, path: String)] = {
        let wanted = [("Claude", "Claude Work"), ("Cursor", "Cursor Client"), ("Google Chrome", "Chrome Testing"),
                      ("Slack", "Slack Client"), ("Visual Studio Code", "Code Side Project"), ("Safari", "Safari Testing")]
        var found: [(String, String)] = []
        for (app, instance) in wanted {
            let path = "/Applications/\(app).app"
            if FileManager.default.fileExists(atPath: path) {
                found.append((instance, path))
            }
        }
        let fallback = [("Notes Work", "/System/Applications/Notes.app"), ("Mail Work", "/System/Applications/Mail.app"),
                        ("Calendar Work", "/System/Applications/Calendar.app")]
        return Array((found + fallback).prefix(3))
    }()
}
