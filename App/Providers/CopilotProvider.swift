import Foundation

/// GitHub Copilot premium-request quota via the internal endpoint the editor plugins use.
/// Token: the OAuth token the Copilot plugin stored in ~/.config/github-copilot/{apps,hosts}.json,
/// or one pasted into settings (e.g. `gh auth token`).
final class CopilotProvider: UsageProvider, @unchecked Sendable {
    let id = ProviderID.copilot
    private(set) var lastRaw: String?

    private let manualToken: String

    init(manualToken: String) {
        self.manualToken = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func fetch() async throws -> ProviderUsage {
        guard let token = manualToken.isEmpty ? Self.findToken() : manualToken else {
            throw ProviderError(signedOut: L("Токен Copilot не найден. Войдите в Copilot в VS Code/JetBrains или вставьте токен в настройках (`gh auth token`).", "No Copilot token found. Sign in to Copilot in VS Code/JetBrains or paste a token in the settings (`gh auth token`)."))
        }

        var request = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        request.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")

        let response = try await HTTP.send(request)
        lastRaw = response.pretty
        try response.check(hint401: L("Токен GitHub недействителен для Copilot", "GitHub token is not valid for Copilot"))

        guard let root = response.json as? [String: Any] else {
            throw ProviderError(L("Неожиданный ответ (см. Диагностику)", "Unexpected response (see Diagnostics)"))
        }

        let reset = J.date(root["quota_reset_date_utc"] ?? root["quota_reset_date"])
        let snapshots = J.dict(root["quota_snapshots"]) ?? [:]

        var windows: [UsageWindow] = []
        for (key, label) in [
            ("premium_interactions", L("Premium-запросы", "Premium requests")),
            ("chat", L("Чат", "Chat")),
            ("completions", L("Автодополнения", "Completions")),
        ] {
            guard let s = J.dict(snapshots[key]),
                  (s["unlimited"] as? Bool) != true,
                  let remainingPct = J.double(s["percent_remaining"])
            else { continue }
            // The free plan reports premium requests as entitlement 0 / 0% remaining: not included, not used up.
            if let entitlement = J.double(s["entitlement"]), entitlement <= 0 { continue }

            var detail: String?
            if let entitlement = J.double(s["entitlement"]), let remaining = J.double(s["remaining"]), entitlement > 0 {
                detail = "\(Int(entitlement - remaining)) / \(Int(entitlement))"
            }
            windows.append(UsageWindow(
                id: key,
                label: label,
                usedPercent: min(max(100 - remainingPct, 0), 100),
                resetsAt: reset,
                detail: detail
            ))
        }

        var usage = ProviderUsage(
            provider: .copilot,
            plan: (root["copilot_plan"] as? String)?.capitalized,
            windows: windows
        )
        if windows.isEmpty { usage.note = L("Безлимитный тариф или квоты не возвращаются", "Unlimited plan, or no quotas returned") }
        return usage
    }

    private static func findToken() -> String? {
        let dir = Paths.home.appendingPathComponent(".config/github-copilot")
        for name in ["apps.json", "hosts.json"] {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            for (key, value) in root where key.hasPrefix("github.com") {
                if let entry = value as? [String: Any],
                   let token = entry["oauth_token"] as? String, !token.isEmpty {
                    return token
                }
            }
        }
        return nil
    }
}
