import SwiftUI
import AppKit

struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.usages.isEmpty {
                Text(model.isRefreshing ? L("Загружаю…", "Loading…") : L("Нет данных. Включите сервисы в настройках.", "No data. Turn on services in the settings."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(model.usages) { usage in
                ProviderCard(usage: usage)
            }

            if let warning = model.storeWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 10) {
                if let t = model.lastRefresh {
                    Text("\(L("обновлено", "updated")) \(t, style: .time)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
                .help(L("Обновить", "Refresh"))

                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "settings")
                } label: {
                    Image(systemName: "gearshape")
                }
                .help(L("Настройки", "Settings"))

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help(L("Выйти", "Quit"))
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 320)
    }
}

struct ProviderCard: View {
    let usage: ProviderUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: usage.provider.symbol)
                    .foregroundStyle(.secondary)
                Text(usage.provider.title)
                    .font(.subheadline.weight(.semibold))
                if let plan = usage.plan {
                    Text(plan)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if usage.stale {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                        .help(L("Показаны прошлые данные: последнее обновление не удалось", "Showing earlier data: the last refresh failed"))
                }
            }

            ForEach(usage.windows) { window in
                WindowRow(window: window)
            }

            if let note = usage.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let error = usage.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
