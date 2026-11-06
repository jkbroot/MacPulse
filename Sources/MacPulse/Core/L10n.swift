import Foundation
import SwiftUI

/// App language. `.system` follows the user's macOS language order: Arabic if Arabic is preferred
/// before English, otherwise English.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ar, en
    var id: String { rawValue }

    /// Shown in its own language so it is recognisable whatever the current UI language is.
    var label: String {
        switch self {
        case .system: T("لغة النظام", "System language")
        case .ar: "العربية"
        case .en: "English"
        }
    }
}

enum L10n {
    /// Read from any thread (sampler labels); written only on the main thread when the setting changes.
    nonisolated(unsafe) private(set) static var isArabic = resolve(.system)

    static func apply(_ lang: AppLanguage) { isArabic = resolve(lang) }

    static func resolve(_ lang: AppLanguage) -> Bool {
        switch lang {
        case .ar: return true
        case .en: return false
        case .system:
            for code in Locale.preferredLanguages {
                if code.hasPrefix("ar") { return true }
                if code.hasPrefix("en") { return false }
            }
            return false
        }
    }

    static var layoutDirection: LayoutDirection { isArabic ? .rightToLeft : .leftToRight }
    static var locale: Locale { Locale(identifier: isArabic ? "ar" : "en") }

    /// Country name in the UI language ("SA" → "السعودية" / "Saudi Arabia").
    static func countryName(_ code: String) -> String {
        locale.localizedString(forRegionCode: code) ?? code
    }
}

/// Inline bilingual string: `T("الذاكرة", "Memory")`.
@inline(__always) func T(_ ar: String, _ en: String) -> String { L10n.isArabic ? ar : en }

/// "SA" → 🇸🇦
func flagEmoji(_ code: String) -> String {
    let base: UInt32 = 0x1F1E6 - 65
    var s = ""
    for u in code.uppercased().unicodeScalars where (65...90).contains(u.value) {
        if let r = Unicode.Scalar(base + u.value) { s.unicodeScalars.append(r) }
    }
    return s
}
