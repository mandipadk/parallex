import Foundation
import MetricKit
import ParallexCore

/// Parallex's own crashes and hangs, as macOS reports them to it (MetricKit
/// delivers them at the next launch, at most once a day), kept for the usage
/// report when it's shared (see `Telemetry.crash`).
final class CrashReports: NSObject, MXMetricManagerSubscriber, Sendable {
    static let shared = CrashReports()

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard Telemetry.consent == .shared else { return }
        for payload in payloads {
            for diagnostic in payload.crashDiagnostics ?? [] {
                if let crash = Telemetry.crash(
                    kind: "crash", callStackTree: diagnostic.callStackTree.jsonRepresentation(),
                    signal: diagnostic.signal?.intValue, exceptionType: diagnostic.exceptionType?.intValue,
                    version: diagnostic.applicationVersion
                ) {
                    Telemetry.recordCrash(crash)
                }
            }
            for diagnostic in payload.hangDiagnostics ?? [] {
                if let hang = Telemetry.crash(
                    kind: "hang", callStackTree: diagnostic.callStackTree.jsonRepresentation(), version: diagnostic.applicationVersion
                ) {
                    Telemetry.recordCrash(hang)
                }
            }
        }
    }
}
