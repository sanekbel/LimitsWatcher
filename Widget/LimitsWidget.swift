import WidgetKit
import SwiftUI

// MARK: - Timeline

struct LimitsEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
    let storeAvailable: Bool
}

struct LimitsTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> LimitsEntry {
        LimitsEntry(date: Date(), snapshot: .sample, storeAvailable: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (LimitsEntry) -> Void) {
        if context.isPreview {
            completion(LimitsEntry(date: Date(), snapshot: .sample, storeAvailable: true))
        } else {
            completion(currentEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LimitsEntry>) -> Void) {
        // The menu bar app also calls WidgetCenter.reloadAllTimelines() after every refresh;
        // this 15-minute fallback only matters if the app isn't running.
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [currentEntry()], policy: .after(next)))
    }

    private func currentEntry() -> LimitsEntry {
        let snapshot = SharedStore.read()
        if let language = snapshot?.language { Loc.language = language }
        return LimitsEntry(date: Date(), snapshot: snapshot, storeAvailable: SharedStore.fileURL != nil)
    }
}

// MARK: - Views

struct LimitsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var systemScheme
    let entry: LimitsEntry

    /// Light / dark picked in the app; nil follows the system.
    private var forcedScheme: ColorScheme? { entry.snapshot?.appearance?.colorScheme }

    var body: some View {
        Group {
            if let snapshot = entry.snapshot, !snapshot.providers.isEmpty {
                content(snapshot)
            } else {
                emptyState
            }
        }
        .environment(\.colorScheme, forcedScheme ?? systemScheme)
        .containerBackground(for: .widget) { background }
        .environment(\.locale, Loc.locale)
    }

    @ViewBuilder
    private var background: some View {
        switch forcedScheme {
        case .dark: Color(white: 0.11)
        case .light: Color(white: 0.97)
        default: Rectangle().fill(.fill.tertiary)
        }
    }

    @ViewBuilder
    private func content(_ snapshot: UsageSnapshot) -> some View {
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 6) {
                ProviderBlock(usage: snapshot.providers[0], maxWindows: 3, compact: false)
                Spacer(minLength: 0)
                Footer(date: snapshot.generatedAt)
            }

        case .systemMedium:
            VStack(alignment: .leading, spacing: 6) {
                ProviderGrid(providers: Array(snapshot.providers.prefix(4)), maxWindows: 2, compact: true)
                Spacer(minLength: 0)
                Footer(date: snapshot.generatedAt)
            }

        default:
            VStack(alignment: .leading, spacing: 8) {
                ProviderGrid(providers: Array(snapshot.providers.prefix(6)), maxWindows: 3, compact: false)
                Spacer(minLength: 0)
                Footer(date: snapshot.generatedAt)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.0percent")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(entry.storeAvailable ? L("Запустите LimitsWatcher", "Launch LimitsWatcher") : L("App Group недоступна. Проверьте подпись (README).", "App Group unavailable. Check code signing (README)."))
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProviderGrid: View {
    let providers: [ProviderUsage]
    let maxWindows: Int
    let compact: Bool

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)],
            alignment: .leading,
            spacing: compact ? 8 : 12
        ) {
            ForEach(providers) { usage in
                ProviderBlock(usage: usage, maxWindows: maxWindows, compact: compact)
            }
        }
    }
}

private struct ProviderBlock: View {
    let usage: ProviderUsage
    let maxWindows: Int
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack(spacing: 4) {
                Image(systemName: usage.provider.symbol).font(.caption2)
                Text(usage.provider.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let plan = usage.plan {
                    Text(plan)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if usage.stale {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            ForEach(usage.windows.prefix(maxWindows)) { window in
                WindowRow(window: window, compact: compact)
            }

            if usage.windows.isEmpty, let error = usage.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct Footer: View {
    let date: Date

    private var isStale: Bool { Date().timeIntervalSince(date) > 30 * 60 }

    var body: some View {
        HStack(spacing: 3) {
            if isStale { Image(systemName: "exclamationmark.triangle.fill") }
            Text("\(L("обновлено", "updated")) \(date, style: .time)")
        }
        .font(.system(size: 9))
        .foregroundStyle(isStale ? Color.orange : Color.secondary)
    }
}

// MARK: - Widget

struct LimitsWidget: Widget {
    let kind = "LimitsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LimitsTimelineProvider()) { entry in
            LimitsWidgetView(entry: entry)
        }
        .configurationDisplayName(L("Лимиты нейронок", "AI Limits"))
        .description(L("Лимиты Claude, Codex, Copilot, Cursor и Gemini на рабочем столе.", "Claude, Codex, Copilot, Cursor and Gemini limits on your desktop."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct LimitsWidgetBundle: WidgetBundle {
    var body: some Widget {
        LimitsWidget()
    }
}
