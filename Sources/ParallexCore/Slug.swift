import Foundation

/// Stable, filesystem- and bundle-ID-safe identifiers derived from instance
/// names: "Claude Work" → "claude-work". Used for the instance directory and
/// the wrapper's CFBundleIdentifier suffix.
public enum Slug {
    public static func make(_ name: String) -> String {
        // Fold diacritics so "Émile" → "emile" rather than dropping the char.
        let folded = name.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var result = ""
        var lastWasDash = true // suppress leading dashes
        for scalar in folded.unicodeScalars {
            if (scalar.value >= 0x61 && scalar.value <= 0x7A) || (scalar.value >= 0x30 && scalar.value <= 0x39) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") {
            result.removeLast()
        }
        return result
    }

    /// The slug for a new instance. Names without Latin letters or digits
    /// ("日本語", "Работа", "🚀") are transliterated first and, failing that,
    /// get a stable identifier derived from the name, so any name works.
    public static func forInstance(named name: String) -> String {
        let direct = make(name)
        // "Работа 2" would otherwise come out as just "2".
        let hasLetters = direct.unicodeScalars.contains { $0.value >= 0x61 && $0.value <= 0x7A }
        if !direct.isEmpty && (hasLetters || !name.unicodeScalars.contains(where: CharacterSet.letters.contains)) {
            return direct
        }
        if let latin = name.applyingTransform(.toLatin, reverse: false) {
            let transliterated = make(latin)
            if !transliterated.isEmpty {
                return transliterated
            }
        }
        // FNV-1a: stable across runs (unlike `hashValue`).
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return "instance-" + String(hash, radix: 36).prefix(8)
    }
}
