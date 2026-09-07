import Foundation

enum WattsFormat {
    // Two decimals under 1 W (stable width for the list column), one decimal
    // at 1 W or above with a trailing zero fraction dropped, always a space
    // before the unit. 0.55 -> "0.55 W", 7.8 -> "7.8 W", 100 -> "100 W".
    // Locale-aware: 7.8 renders "7,8 W" in a comma-decimal region.
    static func string(_ watts: Double, locale: Locale = .current) -> String {
        if watts < 1 {
            return String(format: "%.2f W", locale: locale, watts)
        }
        return "\(oneDecimalTrimmed(watts, locale: locale)) W"
    }

    // One-decimal number with a zero fraction dropped, e.g. 7.8 -> "7.8"
    // and 7.96 -> "8". printf makes the rounding decision: the value is
    // probed with a POSIX "%.1f" (ASCII, locale-independent) and the probe's
    // ".0" suffix decides the precision, which is then rendered in the
    // caller's locale. Two prior versions of this failed by re-deciding what
    // printf had decided: a literal ".0" check missed "8,0" in comma-decimal
    // regions, a separator-aware check missed non-Latin digit zeros (ar/fa),
    // and a numeric re-rounding disagreed with printf at exact .x5 ties
    // (1.05 -> "1.0" vs "1"). All three were review findings on the
    // locale pass.
    // Shared by the watts, volts and amps renderings so the trim cannot
    // drift per unit.
    static func oneDecimalTrimmed(_ value: Double, locale: Locale = .current) -> String {
        let posix = Locale(identifier: "en_US_POSIX")
        let probe = String(format: "%.1f", locale: posix, value)
        if probe.hasSuffix(".0") {
            return String(format: "%.0f", locale: locale, Double(probe) ?? value)
        }
        return String(format: "%.1f", locale: locale, value)
    }
}
