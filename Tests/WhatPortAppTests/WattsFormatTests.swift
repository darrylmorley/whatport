import Testing
@testable import WhatPort
import Foundation

// DAR-353: the zero-fraction trim must fire against the locale's own decimal
// separator. Matching a literal ".0" never fired on "8,0", which left
// comma-decimal regions with a dangling zero on every trimmed reading.
@Suite struct WattsFormatTests {
    private let dutch = Locale(identifier: "nl_NL")
    private let posix = Locale(identifier: "en_US_POSIX")

    @Test func trimsZeroFractionInBothSeparators() {
        #expect(WattsFormat.oneDecimalTrimmed(7.96, locale: posix) == "8")
        #expect(WattsFormat.oneDecimalTrimmed(7.96, locale: dutch) == "8")
        #expect(WattsFormat.oneDecimalTrimmed(7.8, locale: posix) == "7.8")
        #expect(WattsFormat.oneDecimalTrimmed(7.8, locale: dutch) == "7,8")
    }

    // The trim is decided from the value, so it holds in locales whose zero
    // is not an ASCII "0" (both gate reviewers caught the string-matching
    // version missing ar/fa entirely).
    @Test func trimsInNonLatinDigitLocalesAndForNegatives() {
        let arabic = Locale(identifier: "ar_SA")
        #expect(!WattsFormat.oneDecimalTrimmed(8.0, locale: arabic).contains("0"))
        #expect(WattsFormat.oneDecimalTrimmed(8.04, locale: arabic) == WattsFormat.oneDecimalTrimmed(8.0, locale: arabic))
        #expect(WattsFormat.oneDecimalTrimmed(-7.96, locale: posix) == "-8")
        #expect(WattsFormat.oneDecimalTrimmed(-7.8, locale: dutch) == "-7,8")
    }

    // Exact tenths ties: printf decides the rounding, and the trim must
    // agree with it (a numeric re-round returned "1.0" where printf's own
    // decision was "1"; re-verification finding).
    @Test func tiesFollowPrintfsRounding() {
        for value in [1.05, 0.05, 7.95] {
            let plain = String(format: "%.1f", locale: posix, value)
            let expected = plain.hasSuffix(".0") ? String(plain.dropLast(2)) : plain
            #expect(WattsFormat.oneDecimalTrimmed(value, locale: posix) == expected)
        }
    }

    @Test func wattsStringFollowsLocale() {
        #expect(WattsFormat.string(0.55, locale: dutch) == "0,55 W")
        #expect(WattsFormat.string(7.8, locale: dutch) == "7,8 W")
        #expect(WattsFormat.string(100, locale: dutch) == "100 W")
        #expect(WattsFormat.string(7.8, locale: posix) == "7.8 W")
    }
}
