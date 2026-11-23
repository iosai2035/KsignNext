import Foundation

/// Localizable-string helper.
///
/// Strings live in `Localizable.strings` (another builder's files);
/// this helper only centralises lookup, fallback and RTL awareness.
/// It never hard-codes user-visible copy.
public enum Localization {
    /// Returns the localized string for `key`, falling back to `defaultValue`
    /// (or the key itself) when no translation exists.
    public static func string(_ key: String, defaultValue: String? = nil, comment: String = "") -> String {
        let value = NSLocalizedString(key, comment: comment)
        if value != key { return value }
        return defaultValue ?? key
    }

    /// Localized string with `%@` / `%d` style arguments.
    public static func string(_ key: String, arguments: CVarArg..., defaultValue: String? = nil) -> String {
        let format = string(key, defaultValue: defaultValue)
        return String(format: format, arguments: arguments)
    }

    /// The current interface language code, e.g. "en" or "ar".
    public static var currentLanguageCode: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    /// `true` when the current locale is a right-to-left language.
    public static var isRightToLeft: Bool {
        Locale.characterDirection(forLanguage: currentLanguageCode) == .rightToLeft
    }

    /// Text direction for the current locale.
    public static var layoutDirection: Locale.LanguageDirection {
        Locale.characterDirection(forLanguage: currentLanguageCode)
    }

    /// Returns `arabic` when the interface is RTL, otherwise `other`.
    /// Use for choosing mirrored icons / layout variants in code.
    public static func ifRTL<T>(_ rtl: T, _ ltr: T) -> T {
        isRightToLeft ? rtl : ltr
    }
}
