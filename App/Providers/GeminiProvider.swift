import Foundation

/// Gemini CLI quota via Google's Code Assist API, using the Gemini CLI OAuth login (~/.gemini/oauth_creds.json).
///
/// Heads-up: Google stopped serving Gemini CLI OAuth for individual / AI Pro / Ultra accounts on 2026-06-18.
/// This only works for Workspace / Standard / Enterprise accounts; personal accounts get a clear error.
/// The app doesn't refresh the token itself — run `gemini` once and it will.
final class GeminiProvider: UsageProvider, @unchecked Sendable {
    let id = ProviderID.gemini
    private(set) var lastRaw: String?

    func fetch() async throws -> ProviderUsage {
        if let type = Self.authType(), type.contains("api-key") || type.contains("vertex") {
            throw ProviderError(signedOut: L("Gemini CLI настроен на API-ключ/Vertex AI — лимитов подписки нет.", "Gemini CLI uses an API key / Vertex AI — no subscription limits."))
        }

        let file = Paths.home.appendingPathComponent(".gemini/oauth_creds.json")
        guard let data = try? Data(contentsOf: file),
              let creds = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = creds["access_token"] as? String, !token.isEmpty
        else {
            throw ProviderError(signedOut: L("Не найден вход Gemini CLI (~/.gemini/oauth_creds.json). Выполните `gemini`.", "No Gemini CLI login found (~/.gemini/oauth_creds.json). Run `gemini`."))
        }
        if let expiry = J.double(creds["expiry_date"]), expiry / 1000 < Date().timeIntervalSince1970 {
            throw ProviderError(signedOut: L("Токен Gemini истёк — запустите `gemini` один раз, он обновит вход", "Gemini token expired — run `gemini` once to refresh the login"))
        }

        var request = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let response = try await HTTP.send(request)
        lastRaw = response.pretty

        let body = String(decoding: response.data, as: UTF8.self)
        if body.contains("UNSUPPORTED_CLIENT") || body.contains("IneligibleTier") {
            throw ProviderError(signedOut: L("Google отключил Gemini CLI OAuth для личных аккаунтов (с 18.06.2026). Работает только Workspace/Standard.", "Google turned off Gemini CLI OAuth for personal accounts (since 2026-06-18). Only Workspace/Standard works."))
        }
        try response.check(hint401: L("Токен Gemini недействителен — запустите `gemini`", "Gemini token is invalid — run `gemini`"))

        guard let root = response.json as? [String: Any] else {
            throw ProviderError(L("Неожиданный ответ (см. Диагностику)", "Unexpected response (see Diagnostics)"))
        }

        // For each model family keep the bucket with the least quota left.
        var worst: [String: (fraction: Double, reset: Date?)] = [:]
        for bucket in J.array(root["buckets"]) ?? [] {
            guard let model = (bucket["modelId"] as? String)?.lowercased(),
                  let fraction = J.double(bucket["remainingFraction"])
            else { continue }
            let family: String? = model.contains("flash") ? "flash" : (model.contains("pro") ? "pro" : nil)
            guard let family else { continue }
            if let current = worst[family], current.fraction <= fraction { continue }
            worst[family] = (fraction: fraction, reset: J.date(bucket["resetTime"]))
        }

        var windows: [UsageWindow] = []
        for (family, label) in [("pro", L("Pro-модели", "Pro models")), ("flash", L("Flash-модели", "Flash models"))] {
            guard let entry = worst[family] else { continue }
            windows.append(UsageWindow(
                id: family,
                label: label,
                usedPercent: min(max((1 - entry.fraction) * 100, 0), 100),
                resetsAt: entry.reset
            ))
        }
        if windows.isEmpty {
            throw ProviderError(L("В ответе нет квот по моделям — формат мог измениться (см. Диагностику)", "No per-model quotas in the response — the format may have changed (see Diagnostics)"))
        }
        return ProviderUsage(provider: .gemini, windows: windows)
    }

    private static func authType() -> String? {
        let file = Paths.home.appendingPathComponent(".gemini/settings.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let type = root["selectedAuthType"] as? String { return type }
        if let security = root["security"] as? [String: Any],
           let auth = security["auth"] as? [String: Any],
           let type = auth["selectedType"] as? String {
            return type
        }
        return nil
    }
}
