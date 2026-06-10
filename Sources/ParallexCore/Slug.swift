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
}
