import Foundation

/// Claude Pro/Max/Team limits (5-hour session + weekly windows).
///
/// There is no official API for this. The app calls the same undocumented endpoint that
/// Claude Code's own `/usage` uses, authenticated with the OAuth token Claude Code stores locally
/// (~/.claude/.credentials.json, or the "Claude Code-credentials" Keychain item).
/// The token needs the `user:profile` scope — a normal `claude` login has it,
/// a token from `claude setup-token` does not.
final class ClaudeSubscriptionProvider: UsageProvider, @unchecked Sendable {
    let id = ProviderID.claude
    private(set) var lastRaw: String?

    private struct Credentials {
        let token: String
        let plan: String?
    }

    func fetch() async throws -> ProviderUsage {
        let creds = try Self.loadCredentials()

        if let until = Self.backoff.pausedUntil() {
            return try Self.rateLimited(until: until, plan: creds.plan)
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await HTTP.send(request)
        lastRaw = response.pretty
        if response.status == 429 {
            // The limit is per account and shared with every other app using the Claude Code token,
            // so keep polling quietly until it lifts instead of extending it every refresh.
            let until = Self.backoff.hit(retryAfter: response.retryAfter)
            return try Self.rateLimited(until: until, plan: creds.plan)
        }
        try response.check(hint401: L("Токен Claude Code истёк — запустите `claude`, он обновит вход", "Claude Code token expired — run `claude` to refresh the login"))
        Self.backoff.reset()

        guard let root = response.json as? [String: Any] else {
            throw ProviderError(L("Неожиданный ответ (см. Диагностику)", "Unexpected response (see Diagnostics)"))
        }

        var windows: [UsageWindow] = []
        if let w = Self.window(root["five_hour"], id: "session", label: L("Сессия · 5 ч", "Session · 5h")) { windows.append(w) }
        if let w = Self.window(root["seven_day"], id: "weekly", label: L("Неделя", "Week")) { windows.append(w) }

        // Per-model weekly windows: seven_day_opus, seven_day_sonnet, and whatever Anthropic adds later.
        let skipped = ["routines", "cowork", "omelette", "design"]
        for key in root.keys.sorted() where key.hasPrefix("seven_day_") {
            let suffix = String(key.dropFirst("seven_day_".count))
            if skipped.contains(where: { suffix.contains($0) }) { continue }
            if let w = Self.window(root[key], id: key, label: L("Неделя", "Week") + " · \(suffix.capitalized)") {
                windows.append(w)
            }
        }

        if windows.isEmpty {
            throw ProviderError(L("В ответе нет окон лимитов — формат мог измениться (см. Диагностику)", "No limit windows in the response — the format may have changed (see Diagnostics)"))
        }

        var usage = ProviderUsage(provider: .claude, plan: creds.plan, windows: windows)
        if root["five_hour"] is NSNull { usage.note = L("5-часовая сессия не начата", "5-hour session not started") }
        return usage
    }

    private static func window(_ value: Any?, id: String, label: String) -> UsageWindow? {
        guard let d = value as? [String: Any],
              let pct = J.double(d["utilization"] ?? d["utilization_pct"] ?? d["used_percent"])
        else { return nil }
        return UsageWindow(
            id: id,
            label: label,
            usedPercent: min(max(pct, 0), 100),
            resetsAt: J.date(d["resets_at"] ?? d["reset_at"])
        )
    }

    // MARK: Rate limit backoff

    /// Providers are recreated on every refresh, so the backoff state lives in a static.
    private static let backoff = Backoff()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// While the usage endpoint is rate limited, fall back to the numbers Claude Code itself passes
    /// to the statusline (`rate_limits`), if a statusline script saved them to ~/.claude/usage_snapshot.json.
    private static func rateLimited(until: Date, plan: String?) throws -> ProviderUsage {
        let time = timeFormatter.string(from: until)
        let pause = L("пауза до \(time)", "paused until \(time)")
        guard var usage = statuslineUsage(plan: plan) else {
            throw ProviderError(L("429: Anthropic ограничил частоту, \(pause)", "429: rate limited by Anthropic, \(pause)"))
        }
        let taken = timeFormatter.string(from: usage.updatedAt)
        usage.note = L("API отвечает 429 (\(pause)), цифры из statusline Claude Code на \(taken)",
                       "API returns 429 (\(pause)), numbers from the Claude Code statusline at \(taken)")
        return usage
    }

    private static func statuslineUsage(plan: String?, now: Date = Date()) -> ProviderUsage? {
        let file = Paths.home.appendingPathComponent(".claude/usage_snapshot.json")
        guard let data = try? Data(contentsOf: file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = J.dict(root["windows"]),
              let updatedAt = J.date(root["updated_at"])
        else { return nil }

        var windows: [UsageWindow] = []
        for key in raw.keys.sorted(by: { order($0) < order($1) }) {
            guard let d = J.dict(raw[key]), let pct = J.double(d["used_percentage"]) else { continue }
            let label: String
            switch key {
            case "five_hour": label = L("Сессия · 5 ч", "Session · 5h")
            case "seven_day": label = L("Неделя", "Week")
            default:
                guard key.hasPrefix("seven_day_") else { continue }
                label = L("Неделя", "Week") + " · \(key.dropFirst("seven_day_".count).capitalized)"
            }
            // A window that has reset since the snapshot was taken starts again from zero.
            let resetsAt = J.date(d["resets_at"])
            let expired = resetsAt.map { $0 <= now } ?? false
            windows.append(UsageWindow(
                id: key == "five_hour" ? "session" : key == "seven_day" ? "weekly" : key,
                label: label,
                usedPercent: expired ? 0 : min(max(pct, 0), 100),
                resetsAt: expired ? nil : resetsAt
            ))
        }
        guard !windows.isEmpty else { return nil }

        var usage = ProviderUsage(provider: .claude, plan: plan, windows: windows)
        usage.updatedAt = updatedAt
        return usage
    }

    private static func order(_ key: String) -> Int {
        switch key {
        case "five_hour": return 0
        case "seven_day": return 1
        default: return 2
        }
    }

    /// After a 429: wait `Retry-After` if the server sent a positive one, otherwise 5, 10, 20 … up to 60 minutes.
    /// The usage endpoint usually answers `retry-after: 0`, which is useless, so that counts as absent.
    private final class Backoff: @unchecked Sendable {
        private let lock = NSLock()
        private var until: Date?
        private var strikes = 0

        func pausedUntil(now: Date = Date()) -> Date? {
            lock.withLock {
                guard let until, until > now else { return nil }
                return until
            }
        }

        func hit(retryAfter: TimeInterval?, now: Date = Date()) -> Date {
            lock.withLock {
                let exponential = min(5 * 60 * pow(2, Double(strikes)), 60 * 60)
                strikes += 1
                let wait = retryAfter.flatMap { $0 > 0 ? max($0, 60) : nil } ?? exponential
                let next = now.addingTimeInterval(wait)
                until = next
                return next
            }
        }

        func reset() {
            lock.withLock {
                until = nil
                strikes = 0
            }
        }
    }

    // MARK: Credentials

    private static func loadCredentials() throws -> Credentials {
        let file = Paths.home.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), let creds = parse(data) { return creds }
        if let data = Keychain.readForeign(service: "Claude Code-credentials"), let creds = parse(data) { return creds }
        throw ProviderError(signedOut: L("Не найден вход Claude Code. Выполните `claude` и войдите (нужна подписка Pro/Max).", "No Claude Code login found. Run `claude` and sign in (Pro/Max subscription required)."))
    }

    private static func parse(_ data: Data) -> Credentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let plan = planLabel(subscription: oauth["subscriptionType"] as? String,
                             tier: oauth["rateLimitTier"] as? String)
        return Credentials(token: token, plan: plan)
    }

    private static func planLabel(subscription: String?, tier: String?) -> String? {
        if let tier {
            if tier.hasSuffix("max_5x") { return "Max 5x" }
            if tier.hasSuffix("max_20x") { return "Max 20x" }
        }
        guard let subscription, !subscription.isEmpty else { return nil }
        return subscription.capitalized
    }
}
