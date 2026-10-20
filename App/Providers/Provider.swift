import Foundation

// MARK: - Errors, protocol, factory

struct ProviderError: LocalizedError {
    let message: String
    /// No login / token for this service (or it was rejected): the widget hides such providers.
    var signedOut = false
    init(_ message: String) { self.message = message }
    init(signedOut message: String) {
        self.message = message
        self.signedOut = true
    }
    var errorDescription: String? { message }
}

protocol UsageProvider: AnyObject, Sendable {
    var id: ProviderID { get }
    /// Last raw response body (pretty-printed, truncated) for the "Диагностика" tab.
    var lastRaw: String? { get }
    func fetch() async throws -> ProviderUsage
}

enum ProviderFactory {
    static func make(
        enabled: Set<ProviderID>,
        adminKey: String,
        budgetUSD: Double,
        cursorCookie: String,
        copilotToken: String
    ) -> [UsageProvider] {
        ProviderID.allCases
            .filter { enabled.contains($0) }
            .map { id -> UsageProvider in
                switch id {
                case .claude: return ClaudeSubscriptionProvider()
                case .claudeAPI: return ClaudeAdminProvider(adminKey: adminKey, budgetUSD: budgetUSD)
                case .codex: return CodexProvider()
                case .copilot: return CopilotProvider(manualToken: copilotToken)
                case .cursor: return CursorProvider(cookie: cursorCookie)
                case .gemini: return GeminiProvider()
                }
            }
    }
}

// MARK: - Paths

enum Paths {
    /// The app is not sandboxed, so this is the real home directory.
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
}

// MARK: - HTTP

struct HTTPResult {
    let data: Data
    let status: Int
    /// Seconds from the `Retry-After` header (either delta-seconds or an HTTP date), if present.
    var retryAfter: TimeInterval?

    var json: Any? { try? JSONSerialization.jsonObject(with: data) }

    var pretty: String {
        if let obj = json,
           JSONSerialization.isValidJSONObject(obj),
           let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: d, encoding: .utf8) {
            return "HTTP \(status)\n" + String(s.prefix(8000))
        }
        return "HTTP \(status)\n" + String(String(decoding: data, as: UTF8.self).prefix(2000))
    }

    func check(hint401: String? = nil) throws {
        switch status {
        case 200..<300:
            return
        case 401:
            throw ProviderError(signedOut: hint401 ?? L("401: токен недействителен или истёк", "401: token is invalid or expired"))
        case 403:
            let body = String(decoding: data.prefix(400), as: UTF8.self).lowercased()
            if body.contains("<html") || body.contains("cloudflare") {
                throw ProviderError(L("403: запрос заблокирован Cloudflare / сетью", "403: request blocked by Cloudflare / network"))
            }
            if let hint401 { throw ProviderError(signedOut: hint401) }
            throw ProviderError(L("403: доступ запрещён", "403: access denied"))
        case 429:
            throw ProviderError(L("429: слишком много запросов, повторю позже", "429: too many requests, will retry later"))
        default:
            throw ProviderError("HTTP \(status)")
        }
    }
}

enum HTTP {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    static func send(_ request: URLRequest) async throws -> HTTPResult {
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            return HTTPResult(
                data: data,
                status: http?.statusCode ?? 0,
                retryAfter: parseRetryAfter(http?.value(forHTTPHeaderField: "Retry-After"))
            )
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost:
                throw ProviderError(L("Нет сети", "No network"))
            case .timedOut:
                throw ProviderError(L("Таймаут запроса", "Request timed out"))
            default:
                throw ProviderError(L("Сеть: ", "Network: ") + error.localizedDescription)
            }
        }
    }

    private static func parseRetryAfter(_ value: String?) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(seconds, 0) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: value).map { max($0.timeIntervalSinceNow, 0) }
    }
}

// MARK: - Tolerant JSON helpers (these endpoints are undocumented, so every field is optional)

enum J {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoDay: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    static func dict(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [[String: Any]]? {
        value as? [[String: Any]]
    }

    /// ISO-8601 string (with or without fractions, or date-only) or epoch seconds / milliseconds.
    static func date(_ value: Any?) -> Date? {
        if let s = value as? String {
            return isoFractional.date(from: s) ?? isoPlain.date(from: s) ?? isoDay.date(from: s)
        }
        if let d = double(value), d > 0 {
            return Date(timeIntervalSince1970: d > 1e12 ? d / 1000 : d)
        }
        return nil
    }
}
