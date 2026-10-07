import Foundation

/// Character rules shared by name matching, duplicate keys, and file names. They follow .NET's
/// definitions (letters and decimal digits in the Basic Multilingual Plane), so HomeClerkKit
/// produces the same keys and names as the original C# version did — existing file names and the
/// duplicate index depend on them.
enum TextRules {
    static func isLetter(_ s: Unicode.Scalar) -> Bool {
        guard s.value <= 0xFFFF else { return false }
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    static func isLetterOrDigit(_ s: Unicode.Scalar) -> Bool {
        isLetter(s) || (s.value <= 0xFFFF && s.properties.generalCategory == .decimalNumber)
    }

    static func isUppercase(_ s: Unicode.Scalar) -> Bool {
        s.value <= 0xFFFF && s.properties.generalCategory == .uppercaseLetter
    }

    /// Letters and digits only, lowercased: "Acme Tire, Inc." → "acmetireinc".
    static func key(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter(isLetterOrDigit))).lowercased()
    }

    /// Case-insensitive equality, as .NET's OrdinalIgnoreCase compares.
    static func equalsIgnoringCase(_ a: String, _ b: String) -> Bool {
        a.uppercased() == b.uppercased()
    }

    /// Two decimal places, rounding half away from zero: 120.5 → "120.50".
    static func amount(_ value: Decimal) -> String {
        // .plain rounds halves up, so round the magnitude and restore the sign
        var input = value < 0 ? -value : value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 2, .plain)
        if value < 0 { rounded = -rounded }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.minimumIntegerDigits = 1
        formatter.usesGroupingSeparator = false
        return formatter.string(from: rounded as NSDecimalNumber) ?? "\(rounded)"
    }
}

extension Int {
    /// A whole number from a JSON or settings value, or nil when it isn't one that fits.
    /// (Int(Double) crashes on NaN, infinity, and values out of range.)
    init?(checking value: Double) {
        guard value.isFinite, abs(value) < 1e15 else { return nil }
        self.init(value.rounded(.towardZero))
    }
}
