import Foundation
import AppKit
import UserNotifications

/// Usage-threshold and limit-reset notifications.
///
/// Threshold: one notification when a window reaches its provider's threshold; it re-arms only after the
/// window drops back below (normally because the limit reset), and that state survives restarts.
/// Reset: a notification scheduled with the system for the window's `resetsAt`, so it arrives on time even
/// if the app can't poll at that moment. Only for windows that have actually been used.
@MainActor
final class Notifier: ObservableObject {
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined

    private let settings: AppSettings
    private let center = UNUserNotificationCenter.current()
    private let delegate = ForegroundPresenter()
    private let defaults = UserDefaults.standard
    private static let resetPrefix = "reset."

    /// Windows whose threshold notification has been sent, as "provider.window" keys.
    private var notified: Set<String> {
        get { Set(defaults.stringArray(forKey: "notifiedThresholds") ?? []) }
        set { defaults.set(Array(newValue), forKey: "notifiedThresholds") }
    }

    init(settings: AppSettings) {
        self.settings = settings
        center.delegate = delegate
        Task { await refreshAuthorization() }
    }

    var wantsNotifications: Bool { settings.notifyUsage || settings.notifyReset }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    /// Asks once; after a refusal macOS won't ask again and the settings point to System Settings.
    func requestAuthorizationIfNeeded() async {
        await refreshAuthorization()
        guard wantsNotifications, authorization == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        await refreshAuthorization()
    }

    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    func sendTest() async {
        await requestAuthorizationIfNeeded()
        post(id: "test",
             title: "LimitsWatcher",
             body: L("Так будут выглядеть уведомления о лимитах.", "This is how limit notifications will look."))
    }

    /// Called after every refresh with the cards currently shown.
    func process(_ usages: [ProviderUsage]) async {
        await refreshAuthorization()
        checkThresholds(usages)
        await scheduleResets(usages)
    }

    // MARK: Threshold

    private func checkThresholds(_ usages: [ProviderUsage]) {
        var notified = self.notified
        defer { self.notified = notified }

        for usage in usages {
            let threshold = Double(settings.threshold(for: usage.provider))
            for window in usage.windows {
                guard let percent = window.usedPercent else { continue }
                let key = "\(usage.provider.rawValue).\(window.id)"
                if percent < threshold {
                    notified.remove(key)
                    continue
                }
                guard settings.notifyUsage, !notified.contains(key) else { continue }
                notified.insert(key)

                var body = L("\(window.label): использовано \(Fmt.percent(percent))",
                             "\(window.label): \(Fmt.percent(percent)) used")
                if let reset = window.resetsAt {
                    body += L(", сброс через ", ", resets in ") + Fmt.remaining(until: reset)
                }
                post(id: "threshold.\(key)", title: usage.provider.title, body: body)
            }
        }
    }

    // MARK: Reset

    private func scheduleResets(_ usages: [ProviderUsage]) async {
        let pending = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.resetPrefix) }

        var wanted: [String: UNNotificationRequest] = [:]
        if settings.notifyReset, authorization == .authorized || authorization == .provisional {
            for usage in usages {
                for window in usage.windows {
                    guard let reset = window.resetsAt, let percent = window.usedPercent, percent >= 1 else { continue }
                    let interval = reset.timeIntervalSinceNow
                    guard interval > 1 else { continue }
                    let id = Self.resetPrefix + "\(usage.provider.rawValue).\(window.id)"
                    let content = UNMutableNotificationContent()
                    content.title = usage.provider.title
                    content.body = L("Лимит «\(window.label)» сброшен", "The “\(window.label)” limit has reset")
                    content.sound = .default
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
                    wanted[id] = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
                }
            }
        }

        center.removePendingNotificationRequests(withIdentifiers: pending.filter { wanted[$0] == nil })
        // Re-adding with the same identifier replaces the pending one, so the time follows the latest data.
        for request in wanted.values {
            try? await center.add(request)
        }
    }

    // MARK: Posting

    private func post(id: String, title: String, body: String) {
        guard authorization == .authorized || authorization == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

/// The app is a menu bar accessory and often counts as "in the foreground"; show banners anyway.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
