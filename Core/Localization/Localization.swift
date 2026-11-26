import Foundation
import ObjectiveC

/// Localizable-string helper.
///
/// Strings live in `Localizable.strings` (another builder's files);
/// this helper only centralises lookup, fallback and RTL awareness.
/// It never hard-codes user-visible copy.
///
/// Runtime language switching: the Settings language picker writes
/// `ksign.language`, which the SwiftUI `.environment(\.locale)` alone
/// cannot apply to `NSLocalizedString` lookups. `applyLanguage()`
/// installs `LanguageBundle` as the class of `Bundle.main`
/// (`object_setClass`); the override answers every
/// `localizedString(forKey:value:table:)` from the `.lproj` bundle of
/// the selected language, so the next view re-render picks up the new
/// language with no restart. The root view is re-identified on the
/// language key in `KsignNextApp` to force that re-render, and
/// `.environment(\.locale)` is kept alongside it (it drives SwiftUI
/// `LocalizedStringKey` rendering and RTL layout).
public enum Localization {
    /// UserDefaults key for the app-selected interface language.
    public static let languageDefaultsKey = "ksign.language"

    /// The app-selected interface language code ("en" or "ar").
    public static var selectedLanguageCode: String {
        UserDefaults.standard.string(forKey: languageDefaultsKey) ?? "en"
    }

    /// Installs the language-overriding bundle class on `Bundle.main`
    /// (once; later calls are no-ops). Safe to call at launch and on
    /// every language change: the override reads the selected language
    /// from UserDefaults on each lookup, so no re-install is needed
    /// when the language changes.
    public static func applyLanguage() {
        guard object_getClass(Bundle.main) != LanguageBundle.self else { return }
        object_setClass(Bundle.main, LanguageBundle.self)
    }

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
    /// Follows the app-selected language, not the system locale, so
    /// RTL and language-dependent layout follow the toggle.
    public static var currentLanguageCode: String {
        selectedLanguageCode
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

/// A `Bundle` subclass that answers localized-string lookups from the
/// `.lproj` bundle of the app-selected language instead of the system
/// language. Installed on `Bundle.main` by `Localization.applyLanguage`.
/// It has no stored properties, so `object_setClass` on the main bundle
/// is safe. A key missing from the selected language falls back to the
/// English bundle, then to the main bundle's default lookup.
final class LanguageBundle: Bundle {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        for code in [Localization.selectedLanguageCode, "en"] {
            if let path = super.path(forResource: code, ofType: "lproj"),
               let languageBundle = Bundle(path: path) {
                let localized = languageBundle.localizedString(forKey: key, value: value, table: tableName)
                if localized != key { return localized }
            }
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}
