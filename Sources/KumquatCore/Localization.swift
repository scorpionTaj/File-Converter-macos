import Foundation

/// Text shown to people, translated by the app's string catalog (Resources/Localization). Looks in
/// `Bundle.main`, so the app gets its translations while `kumquat-cli` and tests stay in English.
/// Interpolations become format specifiers, as with `String(localized:)`: "\(count) files" → "%lld files".
public func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: .main)
}

/// Translation of text that's already a `String` (a name chosen at run time). Unknown keys come back as is.
public func L(dynamic key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}
