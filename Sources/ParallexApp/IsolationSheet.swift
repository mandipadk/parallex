import SwiftUI
import ParallexCore

/// Results of `IsolationCheck` for one running instance.
struct IsolationSheet: View {
    let entry: InstancesModel.Entry
    @EnvironmentObject private var model: InstancesModel
    @Environment(\.dismiss) private var dismiss
    @State private var report: IsolationReport?
    @State private var errorMessage: String?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.secondary)
                    } else if let report {
                        section(.leak, "Leaks — the original's data in use", color: .red, report: report)
                        section(.sharedByIdentity, "Shared by macOS (keyed by bundle ID; can't be separated)",
                                color: .orange, report: report)
                        section(.sharedByChoice, "Shared on purpose", color: .secondary, report: report)
                        let other = report.findings(in: .other).count
                        if other > 0 {
                            Text("\(other) other open files in your home folder (documents, tool caches).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("This is a snapshot of open files: use the instance for a while (sign in, open a few things) and check again for a fuller picture.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if report?.isClean == false, entry.needsRepair || entry.manifest.settings == nil {
                    Button("Repair Wrapper") {
                        model.repair(entry)
                        dismiss()
                    }
                    .help("Rebuild with the current recipe — takes effect on the next launch")
                }
                Spacer()
                Button("Check Again") { run() }
                    .disabled(checking)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 600, height: 480)
        .onAppear(perform: run)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if checking {
                ProgressView().controlSize(.small)
            } else if let report {
                Image(systemName: report.isClean ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.title)
                    .foregroundStyle(report.isClean ? Color.green : Color.red)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.manifest.name).font(.headline)
                if let report {
                    Text(report.isClean
                         ? "No leaks into \(entry.targetName)'s data found."
                         : "This instance is using \(entry.targetName)'s own data.")
                    Text("\(report.processCount) processes · \(report.findings(in: .isolated).count) files inside the instance directory")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func section(
        _ category: IsolationReport.Category, _ title: String, color: Color, report: IsolationReport
    ) -> some View {
        let findings = report.findings(in: category)
        if !findings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(color)
                ForEach(findings, id: \.path) { finding in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Paths.abbreviate(finding.path))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Text(finding.reason).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func run() {
        let manifest = entry.manifest
        checking = true
        errorMessage = nil
        Task {
            do {
                report = try await Task.detached(priority: .userInitiated) {
                    try IsolationCheck.run(manifest)
                }.value
            } catch {
                errorMessage = "\(error)"
            }
            checking = false
        }
    }
}
