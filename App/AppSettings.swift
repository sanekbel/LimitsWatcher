import Foundation
import Combine
import AppKit

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var enabled: Set<ProviderID> {
        didSet { defaults.set(enabled.map(\.rawValue), forKey: "enabled") }
    }

    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: "language")
            Loc.language = language
        }
    }

    @Published var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appearance")
            applyAppearance()
        }
    }

    /// Display order of all providers. The first one with data goes first in the popover and the widget
    /// and drives the notch outline.
    @Published var order: [ProviderID] {
        didSet { defaults.set(order.map(\.rawValue), forKey: "order") }
    }

    @Published var showNotchOutline: Bool {
        didSet { defaults.set(showNotchOutline, forKey: "showNotchOutline") }
    }

    // MARK: Notifications

    @Published var notifyUsage: Bool {
        didSet { defaults.set(notifyUsage, forKey: "notifyUsage") }
    }

    /// Threshold for every provider, in percent.
    @Published var usageThreshold: Int {
        didSet { defaults.set(usageThreshold, forKey: "usageThreshold") }
    }

    /// When on, `providerThresholds` overrides `usageThreshold` per provider.
    @Published var separateThresholds: Bool {
        didSet { defaults.set(separateThresholds, forKey: "separateThresholds") }
    }

    @Published var providerThresholds: [ProviderID: Int] {
        didSet {
            defaults.set(Dictionary(uniqueKeysWithValues: providerThresholds.map { ($0.key.rawValue, $0.value) }),
                         forKey: "providerThresholds")
        }
    }

    @Published var notifyReset: Bool {
        didSet { defaults.set(notifyReset, forKey: "notifyReset") }
    }

    @Published var refreshMinutes: Int {
        didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes") }
    }

    /// Monthly budget for the Claude API provider, USD. 0 = no budget (show raw spend only).
    @Published var monthlyBudgetUSD: Double {
        didSet { defaults.set(monthlyBudgetUSD, forKey: "monthlyBudgetUSD") }
    }

    @Published var adminKey: String {
        didSet {
            Keychain.set("adminKey", adminKey)
            if oldValue.isEmpty && !adminKey.isEmpty { enabled.insert(.claudeAPI) }
        }
    }

    @Published var cursorCookie: String {
        didSet {
            Keychain.set("cursorCookie", cursorCookie)
            if oldValue.isEmpty && !cursorCookie.isEmpty { enabled.insert(.cursor) }
        }
    }

    /// Optional: overrides the token auto-detected from ~/.config/github-copilot.
    @Published var copilotToken: String {
        didSet { Keychain.set("copilotToken", copilotToken) }
    }

    private init() {
        // Local constant: don't touch `self` before every stored property is initialized.
        let store = UserDefaults.standard
        let saved: Set<ProviderID>? = (store.array(forKey: "enabled") as? [String])
            .map { Set($0.compactMap { ProviderID(rawValue: $0) }) }
        // claudeAPI and cursor need a secret first; they are switched on automatically when one is entered.
        enabled = saved ?? [.claude, .codex, .copilot, .gemini]
        language = store.string(forKey: "language").flatMap(AppLanguage.init(rawValue:)) ?? .system
        appearance = store.string(forKey: "appearance").flatMap(AppAppearance.init(rawValue:)) ?? .system
        let savedOrder = (store.array(forKey: "order") as? [String] ?? []).compactMap { ProviderID(rawValue: $0) }
        order = savedOrder + ProviderID.allCases.filter { !savedOrder.contains($0) }
        showNotchOutline = (store.object(forKey: "showNotchOutline") as? Bool) ?? true
        notifyUsage = (store.object(forKey: "notifyUsage") as? Bool) ?? true
        usageThreshold = (store.object(forKey: "usageThreshold") as? Int) ?? 80
        separateThresholds = store.bool(forKey: "separateThresholds")
        let savedThresholds = store.dictionary(forKey: "providerThresholds") as? [String: Int] ?? [:]
        providerThresholds = Dictionary(uniqueKeysWithValues: savedThresholds.compactMap { key, value in
            ProviderID(rawValue: key).map { ($0, value) }
        })
        notifyReset = (store.object(forKey: "notifyReset") as? Bool) ?? true
        refreshMinutes = (store.object(forKey: "refreshMinutes") as? Int) ?? 5
        monthlyBudgetUSD = store.double(forKey: "monthlyBudgetUSD")
        adminKey = Keychain.get("adminKey") ?? ""
        cursorCookie = Keychain.get("cursorCookie") ?? ""
        copilotToken = Keychain.get("copilotToken") ?? ""
        Loc.language = language
    }

    /// Popover and settings window follow `NSApp.appearance`; nil means the system setting.
    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func threshold(for id: ProviderID) -> Int {
        separateThresholds ? providerThresholds[id] ?? usageThreshold : usageThreshold
    }

    func rank(of id: ProviderID) -> Int {
        order.firstIndex(of: id) ?? order.count
    }

    /// Moves an enabled provider up (-1) or down (+1) among the enabled ones.
    func move(_ id: ProviderID, by offset: Int) {
        let visible = order.filter { enabled.contains($0) }
        guard let i = visible.firstIndex(of: id), visible.indices.contains(i + offset),
              let a = order.firstIndex(of: id), let b = order.firstIndex(of: visible[i + offset])
        else { return }
        order.swapAt(a, b)
    }
}
