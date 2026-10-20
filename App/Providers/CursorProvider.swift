import Foundation

/// Cursor plan usage from cursor.com. Needs the browser session cookie `WorkosCursorSessionToken`
/// (DevTools → Application → Cookies → cursor.com), pasted once into settings.
///
/// Field names below are best-effort: this is a private dashboard API. If a percentage looks wrong
/// or nothing is parsed, open Настройки → Диагностика, copy the JSON, and adjust `parse(_:)`.
final class CursorProvider: UsageProvider, @unchecked Sendable {
    let id = ProviderID.cursor
    private(set) var lastRaw: String?

    private let cookie: String

    init(cookie: String) {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("=") {
            self.cookie = trimmed
        } else {
            self.cookie = "WorkosCursorSessionToken=\(trimmed)"
        }
    }

    func fetch() async throws -> ProviderUsage {
        guard !cookie.isEmpty else {
            throw ProviderError(signedOut: L("Вставьте cookie WorkosCursorSessionToken в настройках.", "Paste the WorkosCursorSessionToken cookie in the settings."))
        }

        var request = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        request.httpShouldHandleCookies = false
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        let response = try await HTTP.send(request)
        lastRaw = response.pretty
        try response.check(hint401: L("Cookie Cursor устарел — скопируйте новый из браузера", "Cursor cookie expired — copy a fresh one from the browser"))

        guard let root = response.json as? [String: Any] else {
            throw ProviderError(L("Неожиданный ответ (см. Диагностику)", "Unexpected response (see Diagnostics)"))
        }
        return try Self.parse(root)
    }

    private static func parse(_ root: [String: Any]) throws -> ProviderUsage {
        let individual = J.dict(root["individualUsage"]) ?? [:]
        let plan = J.dict(individual["plan"]) ?? [:]
        let reset = J.date(root["billingCycleEnd"])

        var windows: [UsageWindow] = []

        if let total = J.double(plan["totalPercentUsed"]) {
            windows.append(UsageWindow(id: "plan", label: L("Тариф", "Plan"), usedPercent: clamp(total), resetsAt: reset))
        } else if let used = J.double(plan["used"]), let limit = J.double(plan["limit"]), limit > 0 {
            windows.append(UsageWindow(
                id: "plan", label: L("Тариф", "Plan"), usedPercent: clamp(used / limit * 100), resetsAt: reset,
                detail: String(format: "$%.2f / $%.0f", used / 100, limit / 100)
            ))
        }
        if let auto = J.double(plan["autoPercentUsed"]) {
            windows.append(UsageWindow(id: "auto", label: "Auto + Composer", usedPercent: clamp(auto), resetsAt: reset))
        }
        if let api = J.double(plan["apiPercentUsed"]) {
            windows.append(UsageWindow(id: "api", label: L("API (именные модели)", "API (named models)"), usedPercent: clamp(api), resetsAt: reset))
        }

        guard !windows.isEmpty else {
            throw ProviderError(L("Не удалось разобрать ответ — формат мог измениться (см. Диагностику)", "Could not parse the response — the format may have changed (see Diagnostics)"))
        }

        var usage = ProviderUsage(
            provider: .cursor,
            plan: (root["membershipType"] as? String)?.capitalized,
            windows: windows
        )
        if let onDemand = J.dict(individual["onDemand"]),
           (onDemand["enabled"] as? Bool) == true,
           let used = J.double(onDemand["used"]), used > 0 {
            usage.note = String(format: "On-demand: $%.2f", used / 100)
        }
        return usage
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}
