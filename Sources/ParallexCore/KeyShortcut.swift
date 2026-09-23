import Foundation

/// A global keyboard shortcut that opens an instance, stored with the
/// instance so it follows renames and shows up wherever the instance does.
///
/// `keyCode` is the hardware virtual key code (layout independent, what the
/// hotkey API registers); `key` is what the key printed when it was
/// recorded, kept for display.
public struct KeyShortcut: Codable, Sendable, Hashable {
    public struct Modifiers: OptionSet, Codable, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public var keyCode: UInt16
    public var modifiers: Modifiers
    public var key: String

    public init(keyCode: UInt16, modifiers: Modifiers, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// Menu-style rendering: "⌃⌥1", "⇧⌘F5".
    public var displayString: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols + key
    }

    /// Whether two shortcuts are the same key chord (display text aside).
    public func sameKeys(as other: KeyShortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    /// Whether this is safe to register system-wide. A global shortcut needs
    /// ⌃ or ⌥: plain keys and ⇧ would eat typing, and ⌘ chords (⌘C, ⌘W,
    /// ⇧⌘N…) belong to the app in front. Function keys aren't typed, so they
    /// may stand alone.
    public var isValidGlobal: Bool {
        !modifiers.intersection([.control, .option]).isEmpty || Self.functionKeyCodes.values.contains(keyCode)
    }

    // MARK: - Parsing

    /// Parse a shortcut typed on the command line: "ctrl+opt+1",
    /// "cmd+shift+k", "⌃⌥P", "f5". Keys are matched on the US layout, which
    /// is what key codes describe.
    public init?(parsing text: String) {
        var modifiers: Modifiers = []
        var remainder = Substring(text.trimmingCharacters(in: .whitespaces))
        let symbolMap: [Character: Modifiers] = ["⌃": .control, "⌥": .option, "⇧": .shift, "⌘": .command]
        while let first = remainder.first, let modifier = symbolMap[first] {
            modifiers.insert(modifier)
            remainder = remainder.dropFirst()
        }
        var parts = remainder.split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        // "ctrl++" or a trailing "+" means the plus key itself.
        if parts.count >= 2, parts.last == "", parts[parts.count - 2] == "" {
            parts.removeLast(2)
            parts.append("=")
        }
        guard let keyName = parts.popLast(), !keyName.isEmpty else { return nil }
        let names: [String: Modifiers] = [
            "ctrl": .control, "control": .control, "⌃": .control,
            "opt": .option, "option": .option, "alt": .option, "⌥": .option,
            "shift": .shift, "⇧": .shift,
            "cmd": .command, "command": .command, "⌘": .command,
        ]
        for part in parts {
            guard let modifier = names[part] else { return nil }
            modifiers.insert(modifier)
        }
        guard let (code, display) = Self.key(named: keyName) else { return nil }
        self.init(keyCode: code, modifiers: modifiers, key: display)
    }

    private static func key(named name: String) -> (UInt16, String)? {
        if let code = letterCodes[name] { return (code, name.uppercased()) }
        if let code = digitCodes[name] { return (code, name) }
        if let code = functionKeyCodes[name] { return (code, name.uppercased()) }
        if let (code, display) = namedKeys[name] { return (code, display) }
        return nil
    }

    /// How to show a key that doesn't type a character (function keys,
    /// arrows, Space…), or nil for ordinary character keys.
    public static func symbol(forKeyCode code: UInt16) -> String? {
        if let name = functionKeyCodes.first(where: { $0.value == code })?.key {
            return name.uppercased()
        }
        let special: [UInt16: String] = [
            0x31: "Space", 0x24: "↩", 0x30: "⇥", 0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
            0x33: "⌫", 0x75: "⌦", 0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
        ]
        return special[code]
    }

    // ANSI virtual key codes (Carbon's kVK_* values).
    static let letterCodes: [String: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
        "n": 0x2D, "m": 0x2E,
    ]
    static let digitCodes: [String: UInt16] = [
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C,
        "9": 0x19, "0": 0x1D,
    ]
    static let functionKeyCodes: [String: UInt16] = [
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62,
        "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F, "f13": 0x69, "f14": 0x6B,
        "f15": 0x71, "f16": 0x6A, "f17": 0x40, "f18": 0x4F, "f19": 0x50, "f20": 0x5A,
    ]
    static let namedKeys: [String: (UInt16, String)] = [
        "space": (0x31, "Space"), "return": (0x24, "↩"), "enter": (0x24, "↩"), "tab": (0x30, "⇥"),
        "left": (0x7B, "←"), "right": (0x7C, "→"), "down": (0x7D, "↓"), "up": (0x7E, "↑"),
        "-": (0x1B, "-"), "=": (0x18, "="), "[": (0x21, "["), "]": (0x1E, "]"), ";": (0x29, ";"),
        "'": (0x27, "'"), ",": (0x2B, ","), ".": (0x2F, "."), "/": (0x2C, "/"), "\\": (0x2A, "\\"),
        "`": (0x32, "`"),
    ]
}
