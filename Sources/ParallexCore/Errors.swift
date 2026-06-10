/// A user-facing error. The CLI prints `Error: <description>`; the GUI shows
/// it in an alert — so the message should be a complete, actionable sentence.
public struct ParallexError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public var description: String { message }

    public init(_ message: String) {
        self.message = message
    }
}
