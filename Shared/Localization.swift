import Foundation

/// UI language picked in the settings. `.system` follows macOS: Russian if it comes first, English otherwise.
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system, ru, en

    var id: String { rawValue }

    /// Shown in the picker; each language names itself so it can be found from either.
    var title: String {
        switch self {
        case .system: return L("Как в системе", "System")
        case .ru: return "Русский"
        case .en: return "English"
        }
    }
}

/// The app sets the language from its settings, the widget from the snapshot the app wrote.
/// Providers read it from background tasks, hence the lock.
enum Loc {
    private static let lock = NSLock()
    private static var _language: AppLanguage = .system

    static var language: AppLanguage {
        get { lock.withLock { _language } }
        set { lock.withLock { _language = newValue } }
    }

    static var isRussian: Bool {
        switch language {
        case .ru: return true
        case .en: return false
        case .system: return Locale.preferredLanguages.first?.hasPrefix("ru") ?? false
        }
    }

    static var locale: Locale { Locale(identifier: isRussian ? "ru_RU" : "en_US") }
}

/// The Russian or English variant, depending on the current UI language.
func L(_ ru: String, _ en: String) -> String {
    Loc.isRussian ? ru : en
}
