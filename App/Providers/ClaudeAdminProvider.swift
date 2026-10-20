import Foundation

/// Claude API spend for the current calendar month (UTC) via the Admin API cost report.
/// Needs an organization Admin API key (`sk-ant-admin…`); individual accounts don't have one.
/// There is no "limit" in the API itself, so a percentage is only shown if you set a monthly budget.
final class ClaudeAdminProvider: UsageProvider, @unchecked Sendable {
    let id = ProviderID.claudeAPI
    private(set) var lastRaw: String?

    private let key: String
    private let budget: Double

    init(adminKey: String, budgetUSD: Double) {
        key = adminKey.trimmingCharacters(in: .whitespacesAndNewlines)
        budget = budgetUSD
    }

    func fetch() async throws -> ProviderUsage {
        guard key.hasPrefix("sk-ant-admin") else {
            throw ProviderError(signedOut: L("Нужен Admin API key (sk-ant-admin…): Claude Console → Settings → Admin keys. Доступен только организациям.", "Admin API key required (sk-ant-admin…): Claude Console → Settings → Admin keys. Organizations only."))
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart

        let iso = ISO8601DateFormatter()
        var totalCents = 0.0
        var page: String? = nil

        for _ in 0..<5 {
            var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
            var items = [
                URLQueryItem(name: "starting_at", value: iso.string(from: monthStart)),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: "31"),
            ]
            if let page { items.append(URLQueryItem(name: "page", value: page)) }
            components.queryItems = items

            var request = URLRequest(url: components.url!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

            let response = try await HTTP.send(request)
            lastRaw = response.pretty
            try response.check(hint401: L("Admin API key недействителен", "Admin API key is invalid"))

            guard let root = response.json as? [String: Any] else {
                throw ProviderError(L("Неожиданный ответ (см. Диагностику)", "Unexpected response (see Diagnostics)"))
            }
            for bucket in J.array(root["data"]) ?? [] {
                for item in J.array(bucket["results"]) ?? [] {
                    totalCents += J.double(item["amount"]) ?? 0
                }
            }
            if (root["has_more"] as? Bool) == true, let next = root["next_page"] as? String {
                page = next
            } else {
                break
            }
        }

        let dollars = totalCents / 100
        let window: UsageWindow
        if budget > 0 {
            window = UsageWindow(
                id: "month",
                label: L("Расход · месяц", "Spend · month"),
                usedPercent: min(dollars / budget * 100, 100),
                resetsAt: nextMonth,
                detail: String(format: "$%.2f / $%.0f", dollars, budget)
            )
        } else {
            window = UsageWindow(
                id: "month",
                label: L("Расход · месяц", "Spend · month"),
                usedPercent: nil,
                resetsAt: nextMonth,
                detail: String(format: "$%.2f", dollars)
            )
        }
        return ProviderUsage(provider: .claudeAPI, plan: "Admin API", windows: [window])
    }
}
