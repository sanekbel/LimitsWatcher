import Foundation

// MARK: - Provider identity

enum ProviderID: String, Codable, CaseIterable, Identifiable {
    case claude, claudeAPI, codex, copilot, cursor, gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .claudeAPI: return "Claude API"
        case .codex: return "Codex / ChatGPT"
        case .copilot: return "GitHub Copilot"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini"
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .claudeAPI: return "dollarsign.circle"
        case .codex: return "terminal"
        case .copilot: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        case .gemini: return "diamond"
        }
    }
}

// MARK: - Usage model (shared between the menu bar app and the widget)

struct UsageWindow: Codable, Identifiable {
    var id: String
    var label: String
    /// 0...100. nil means "no percentage, show `detail` only" (e.g. API spend without a budget).
    var usedPercent: Double?
    var resetsAt: Date?
    var detail: String?
}

struct ProviderUsage: Codable, Identifiable {
    var provider: ProviderID
    var plan: String? = nil
    var windows: [UsageWindow] = []
    var note: String? = nil
    var error: String? = nil
    /// true when `windows` are from an earlier successful fetch and the latest fetch failed
    var stale: Bool = false
    var updatedAt: Date = Date()

    var id: String { provider.rawValue }
}

struct UsageSnapshot: Codable {
    var providers: [ProviderUsage]
    var generatedAt: Date
    /// The language picked in the app, so the widget's own strings match the card labels. Optional for older snapshots.
    var language: AppLanguage? = nil
    /// Light / dark choice from the app, applied to the widget too. Optional for older snapshots.
    var appearance: AppAppearance? = nil
}

extension UsageSnapshot {
    /// Used for the widget placeholder / gallery preview.
    static var sample: UsageSnapshot {
        let now = Date()
        return UsageSnapshot(
            providers: [
                ProviderUsage(provider: .claude, plan: "Max 5x", windows: [
                    UsageWindow(id: "session", label: L("Сессия · 5 ч", "Session · 5h"), usedPercent: 42, resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60)),
                    UsageWindow(id: "weekly", label: L("Неделя", "Week"), usedPercent: 67, resetsAt: now.addingTimeInterval(3 * 86400)),
                ]),
                ProviderUsage(provider: .codex, plan: "Plus", windows: [
                    UsageWindow(id: "primary", label: L("Сессия · 5 ч", "Session · 5h"), usedPercent: 12, resetsAt: now.addingTimeInterval(4 * 3600)),
                    UsageWindow(id: "secondary", label: L("Неделя", "Week"), usedPercent: 31, resetsAt: now.addingTimeInterval(5 * 86400)),
                ]),
                ProviderUsage(provider: .copilot, plan: "Pro", windows: [
                    UsageWindow(id: "premium", label: L("Premium-запросы", "Premium requests"), usedPercent: 88, resetsAt: now.addingTimeInterval(11 * 86400), detail: "264 / 300"),
                ]),
                ProviderUsage(provider: .cursor, plan: "Pro", windows: [
                    UsageWindow(id: "plan", label: L("Тариф", "Plan"), usedPercent: 54, resetsAt: now.addingTimeInterval(9 * 86400)),
                ]),
            ],
            generatedAt: now
        )
    }
}
