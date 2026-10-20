import SwiftUI

/// Light / dark choice from the settings; `.system` follows macOS.
enum AppAppearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("Как в системе", "System")
        case .light: return L("Светлая", "Light")
        case .dark: return L("Тёмная", "Dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
