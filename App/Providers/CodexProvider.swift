import Foundation

/// Codex / ChatGPT plan limits via the same endpoint Codex CLI uses.
/// Auth comes from the Codex CLI login (~/.codex/auth.json). The app never refreshes that token itself —
/// the refresh token is single-use and rotating it here would log the CLI out.
final class CodexProvider: UsageProvider, @unchecked Sendable {
    let id = ProviderID.codex
    private(set) var lastRaw: String?

    func fetch() async throws -> ProviderUsage {
        let (token, accountID) = try Self.loadAuth()

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let accountID { request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id") }
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await HTTP.send(request)
        lastRaw = response.pretty
        try response.check(hint401: L("Токен Codex устарел — запустите `codex`, он обновит вход", "Codex token expired — run `codex` to refresh the login"))

        guard let root = response.json as? [String: Any] else {
            throw ProviderError(L("Неожиданный ответ (см. Диагностику)", "Unexpected response (see Diagnostics)"))
        }

        let limits = J.dict(root["rate_limit"]) ?? [:]
        var windows: [UsageWindow] = []
        for (index, key) in ["primary_window", "secondary_window"].enumerated() {
            if let w = Self.window(limits[key], fallbackID: index == 0 ? "primary" : "secondary") {
                windows.append(w)
            }
        }
        if windows.isEmpty {
            throw ProviderError(L("В ответе нет окон лимитов — формат мог измениться (см. Диагностику)", "No limit windows in the response — the format may have changed (see Diagnostics)"))
        }

        var usage = ProviderUsage(
            provider: .codex,
            plan: (root["plan_type"] as? String)?.capitalized,
            windows: windows
        )
        if let credits = J.dict(root["credits"]),
           (credits["has_credits"] as? Bool) == true,
           let balance = J.double(credits["balance"]) {
            usage.note = String(format: L("Кредиты: %.0f", "Credits: %.0f"), balance)
        }
        return usage
    }

    private static func window(_ value: Any?, fallbackID: String) -> UsageWindow? {
        guard let d = value as? [String: Any], let used = J.double(d["used_percent"]) else { return nil }
        let seconds = J.double(d["limit_window_seconds"])
        var reset = J.date(d["reset_at"])
        if reset == nil, let after = J.double(d["reset_after_seconds"]) {
            reset = Date().addingTimeInterval(after)
        }
        return UsageWindow(
            id: fallbackID,
            label: label(forSeconds: seconds, fallback: fallbackID == "primary" ? L("Сессия", "Session") : L("Неделя", "Week")),
            usedPercent: min(max(used, 0), 100),
            resetsAt: reset
        )
    }

    private static func label(forSeconds seconds: Double?, fallback: String) -> String {
        guard let s = seconds, s > 0 else { return fallback }
        if abs(s - 18000) < 120 { return L("Сессия · 5 ч", "Session · 5h") }
        if abs(s - 604800) < 3600 { return L("Неделя", "Week") }
        if s.truncatingRemainder(dividingBy: 86400) == 0 { return L("\(Int(s / 86400)) дн", "\(Int(s / 86400))d") }
        return L("\(Int((s / 3600).rounded())) ч", "\(Int((s / 3600).rounded()))h")
    }

    private static func loadAuth() throws -> (token: String, accountID: String?) {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? Paths.home.appendingPathComponent(".codex")
        let file = home.appendingPathComponent("auth.json")

        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ProviderError(signedOut: L("Не найден вход Codex (~/.codex/auth.json). Выполните `codex login`.", "No Codex login found (~/.codex/auth.json). Run `codex login`."))
        }
        guard let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty
        else {
            throw ProviderError(signedOut: L("Codex вошёл по API-ключу — лимитов подписки нет.", "Codex is signed in with an API key — no subscription limits."))
        }
        return (access, tokens["account_id"] as? String)
    }
}
