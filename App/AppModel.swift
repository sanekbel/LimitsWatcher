import SwiftUI
import Combine
import WidgetKit
import AppKit

private struct FetchOutcome: Sendable {
    let usage: ProviderUsage
    let raw: String?
    var signedOut = false
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var usages: [ProviderUsage] = []
    @Published private(set) var raw: [ProviderID: String] = [:]
    /// Services without a login, hidden from the popover and the widget; the message says how to log in.
    @Published private(set) var signedOut: [ProviderID: String] = [:]
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var storeWarning: String?

    let settings = AppSettings.shared

    private var timer: Timer?
    /// A refresh was asked for while one was running (e.g. the language changed mid-fetch).
    private var refreshAgain = false
    private var bag = Set<AnyCancellable>()
    private var notch: NotchOutlineController?
    let notifier: Notifier

    private init() {
        notifier = Notifier(settings: AppSettings.shared)

        // Show whatever the last run wrote while the first refresh is in flight.
        if let cached = SharedStore.read() {
            usages = cached.providers
            lastRefresh = cached.generatedAt
        }

        settings.$refreshMinutes
            .sink { [weak self] minutes in self?.scheduleTimer(minutes: minutes) }
            .store(in: &bag)

        // Card labels and messages are built during a fetch, so a new language needs a refresh.
        settings.$language
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in Task { await self?.refresh() } }
            .store(in: &bag)

        // Any notification setting: ask for permission if needed and re-check against the current numbers.
        Publishers.MergeMany(
            settings.$notifyUsage.map { _ in () }.eraseToAnyPublisher(),
            settings.$notifyReset.map { _ in () }.eraseToAnyPublisher(),
            settings.$usageThreshold.map { _ in () }.eraseToAnyPublisher(),
            settings.$separateThresholds.map { _ in () }.eraseToAnyPublisher(),
            settings.$providerThresholds.map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst(5)
        .debounce(for: .seconds(0.8), scheduler: RunLoop.main)
        .sink { [weak self] in
            guard let self else { return }
            Task {
                await self.notifier.requestAuthorizationIfNeeded()
                await self.notifier.process(self.usages)
            }
        }
        .store(in: &bag)

        settings.applyAppearance()
        // The widget takes the appearance from the snapshot; no fetch needed.
        settings.$appearance
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.publish() }
            .store(in: &bag)

        // Reordering needs no fetch: re-sort what we have and hand it to the widget.
        settings.$order
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyOrder() }
            .store(in: &bag)

        settings.$enabled
            .dropFirst()
            .debounce(for: .seconds(0.6), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { await self?.refresh() } }
            .store(in: &bag)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .delay(for: .seconds(5), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { await self?.refresh() } }
            .store(in: &bag)

        notch = NotchOutlineController(model: self, settings: settings)
        Task { await refresh() }
    }

    /// The worst "first window" percentage across providers, shown next to the menu bar icon.
    var menuBarText: String? {
        let values = usages.compactMap { $0.windows.first?.usedPercent }
        guard let maxValue = values.max() else { return nil }
        return Fmt.percent(maxValue)
    }

    private func scheduleTimer(minutes: Int) {
        timer?.invalidate()
        let interval = TimeInterval(max(minutes, 1) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        guard !isRefreshing else {
            refreshAgain = true
            return
        }
        repeat {
            refreshAgain = false
            isRefreshing = true
            await refreshOnce()
            isRefreshing = false
        } while refreshAgain
    }

    private func refreshOnce() async {

        let previous = Dictionary(usages.map { ($0.provider, $0) }, uniquingKeysWith: { first, _ in first })
        let providers = ProviderFactory.make(
            enabled: settings.enabled,
            adminKey: settings.adminKey,
            budgetUSD: settings.monthlyBudgetUSD,
            cursorCookie: settings.cursorCookie,
            copilotToken: settings.copilotToken
        )

        var outcomes: [FetchOutcome] = []
        await withTaskGroup(of: FetchOutcome.self) { group in
            for provider in providers {
                let prev = previous[provider.id]
                group.addTask { await AppModel.run(provider, previous: prev) }
            }
            for await outcome in group { outcomes.append(outcome) }
        }

        outcomes.sort { settings.rank(of: $0.usage.provider) < settings.rank(of: $1.usage.provider) }
        usages = outcomes.filter { !$0.signedOut }.map(\.usage)
        signedOut = Dictionary(
            outcomes.filter(\.signedOut).map { ($0.usage.provider, $0.usage.error ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        for outcome in outcomes {
            if let text = outcome.raw { raw[outcome.usage.provider] = text }
        }
        lastRefresh = Date()
        publish()
        await notifier.requestAuthorizationIfNeeded()
        await notifier.process(usages)
    }

    /// Called via `receive(on:)`, i.e. after `order` has actually been stored (`$order` fires on willSet).
    private func applyOrder() {
        usages.sort { settings.rank(of: $0.provider) < settings.rank(of: $1.provider) }
        publish()
    }

    /// Writes the snapshot for the widget and asks WidgetKit to redraw.
    private func publish() {
        let snapshot = UsageSnapshot(
            providers: usages,
            generatedAt: lastRefresh ?? Date(),
            language: settings.language,
            appearance: settings.appearance
        )
        if SharedStore.fileURL == nil {
            storeWarning = L("App Group недоступна — виджет не получит данные. Проверьте подпись (см. README).", "App Group unavailable — the widget won't get data. Check code signing (see README).")
        } else {
            storeWarning = nil
            try? SharedStore.write(snapshot)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    nonisolated private static func run(_ provider: UsageProvider, previous: ProviderUsage?) async -> FetchOutcome {
        do {
            let usage = try await provider.fetch()
            return FetchOutcome(usage: usage, raw: provider.lastRaw)
        } catch {
            let providerError = error as? ProviderError
            let message = providerError?.message ?? error.localizedDescription
            // Keep the last good numbers on screen (marked stale) instead of blanking the card.
            var usage = previous ?? ProviderUsage(provider: provider.id)
            usage.error = message
            usage.stale = !usage.windows.isEmpty
            return FetchOutcome(usage: usage, raw: provider.lastRaw, signedOut: providerError?.signedOut ?? false)
        }
    }
}
