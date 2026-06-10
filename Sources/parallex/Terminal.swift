import Foundation

/// ANSI styling that degrades to plain text when stdout isn't a terminal
/// (pipes, command substitution, CI).
enum Term {
    static let isTTY = isatty(STDOUT_FILENO) == 1

    private static func style(_ code: String, _ text: String) -> String {
        isTTY ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    static func bold(_ text: String) -> String { style("1", text) }
    static func dim(_ text: String) -> String { style("2", text) }
    static func red(_ text: String) -> String { style("31", text) }
    static func green(_ text: String) -> String { style("32", text) }
    static func yellow(_ text: String) -> String { style("33", text) }
    static func cyan(_ text: String) -> String { style("36", text) }

    /// Print a warning line to stdout, prefixed with a yellow ⚠.
    static func warn(_ message: String) {
        print(yellow("⚠ ") + message)
    }
}
