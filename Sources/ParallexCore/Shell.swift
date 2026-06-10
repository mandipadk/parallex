import Foundation

/// Minimal subprocess runner for the handful of system tools we shell out to
/// (codesign, xattr, iconutil, lsregister, open).
public enum Shell {
    public struct CommandFailure: Error, CustomStringConvertible, Sendable {
        public let tool: String
        public let arguments: [String]
        public let exitCode: Int32
        public let stderr: String

        public var description: String {
            var text = "\(tool) \(arguments.joined(separator: " ")) failed with exit code \(exitCode)"
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                text += ":\n\(trimmed)"
            }
            return text
        }
    }

    /// Run a tool (absolute path) and return its stdout. Throws on a non-zero
    /// exit, with stderr included in the error.
    @discardableResult
    public static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Drain the pipes before waiting so a chatty tool can't deadlock us.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CommandFailure(
                tool: tool,
                arguments: arguments,
                exitCode: process.terminationStatus,
                stderr: String(decoding: errData, as: UTF8.self)
            )
        }
        return String(decoding: outData, as: UTF8.self)
    }

    /// Run a tool where failure is acceptable (e.g. clearing a quarantine
    /// attribute that isn't there). Returns whether it succeeded.
    @discardableResult
    public static func runAllowingFailure(_ tool: String, _ arguments: [String]) -> Bool {
        (try? run(tool, arguments)) != nil
    }
}
