import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        TabView {
            ServicesTab()
                .tabItem { Label(L("Сервисы", "Services"), systemImage: "square.stack.3d.up") }
            GeneralTab()
                .tabItem { Label(L("Общие", "General"), systemImage: "gearshape") }
            NotificationsTab()
                .environmentObject(model.notifier)
                .tabItem { Label(L("Уведомления", "Notifications"), systemImage: "bell") }
            DiagnosticsTab()
                .tabItem { Label(L("Диагностика", "Diagnostics"), systemImage: "stethoscope") }
        }
        .frame(width: 540, height: 520)
    }
}

// MARK: - Services

private struct ServicesTab: View {
    @EnvironmentObject var settings: AppSettings

    private func binding(_ id: ProviderID) -> Binding<Bool> {
        Binding(
            get: { settings.enabled.contains(id) },
            set: { on in
                if on { settings.enabled.insert(id) } else { settings.enabled.remove(id) }
            }
        )
    }

    var body: some View {
        Form {
            let visible = settings.order.filter { settings.enabled.contains($0) }
            if visible.count > 1 {
                Section {
                    ForEach(Array(visible.enumerated()), id: \.element) { index, id in
                        HStack {
                            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Image(systemName: id.symbol).foregroundStyle(.secondary)
                            Text(id.title)
                            Spacer()
                            Button { settings.move(id, by: -1) } label: { Image(systemName: "chevron.up") }
                                .disabled(index == 0)
                                .help(L("Выше", "Move up"))
                            Button { settings.move(id, by: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(index == visible.count - 1)
                                .help(L("Ниже", "Move down"))
                        }
                        .buttonStyle(.borderless)
                    }
                    hint(L("Первый сервис с данными идёт первым в меню и виджете, показывается в маленьком виджете и в обводке выреза.",
                           "The first service with data comes first in the menu and the widget, fills the small widget and the notch outline."))
                } header: {
                    Text(L("Порядок", "Order"))
                }
            }

            Section {
                Toggle(ProviderID.claude.title + L(" (подписка)", " (subscription)"), isOn: binding(.claude))
                hint(L("Берёт вход из Claude Code (~/.claude или Keychain). Нужна подписка Pro/Max/Team и `claude` с логином. При первом запуске macOS спросит доступ к Keychain — выберите «Всегда разрешать».",
                       "Uses the Claude Code login (~/.claude or Keychain). Needs a Pro/Max/Team subscription and a signed-in `claude`. On first run macOS asks for Keychain access — choose “Always Allow”."))
            }

            Section {
                Toggle(ProviderID.claudeAPI.title, isOn: binding(.claudeAPI))
                SecureField("Admin API key (sk-ant-admin…)", text: $settings.adminKey)
                TextField(L("Месячный бюджет, $ (необязательно)", "Monthly budget, $ (optional)"), value: $settings.monthlyBudgetUSD, format: .number)
                hint(L("Расход за текущий месяц. У API нет «лимита», процент появится только если задан бюджет. Admin-ключи есть только у организаций.",
                       "Spend for the current month. The API has no “limit”, so a percentage appears only with a budget set. Admin keys are for organizations only."))
            }

            Section {
                Toggle(ProviderID.codex.title, isOn: binding(.codex))
                hint(L("Берёт вход из Codex CLI (~/.codex/auth.json). Если пишет «токен устарел» — запустите `codex` один раз.",
                       "Uses the Codex CLI login (~/.codex/auth.json). If it says the token expired, run `codex` once."))
            }

            Section {
                Toggle(ProviderID.copilot.title, isOn: binding(.copilot))
                SecureField(L("GitHub token (необязательно)", "GitHub token (optional)"), text: $settings.copilotToken)
                hint(L("По умолчанию токен берётся из ~/.config/github-copilot (его создаёт плагин Copilot в VS Code/JetBrains). Можно вставить свой, например из `gh auth token`.",
                       "By default the token comes from ~/.config/github-copilot (created by the Copilot plugin in VS Code/JetBrains). You can paste your own, e.g. from `gh auth token`."))
            }

            Section {
                Toggle(ProviderID.cursor.title, isOn: binding(.cursor))
                SecureField("Cookie WorkosCursorSessionToken", text: $settings.cursorCookie)
                hint(L("Откройте cursor.com в браузере → DevTools → Application → Cookies → скопируйте значение WorkosCursorSessionToken (или весь заголовок Cookie).",
                       "Open cursor.com in a browser → DevTools → Application → Cookies → copy the WorkosCursorSessionToken value (or the whole Cookie header)."))
            }

            Section {
                Toggle(ProviderID.gemini.title, isOn: binding(.gemini))
                hint(L("Берёт вход из Gemini CLI (~/.gemini). С 18.06.2026 Google не обслуживает этот вход для личных аккаунтов — работает только Workspace/Standard.",
                       "Uses the Gemini CLI login (~/.gemini). Since 2026-06-18 Google no longer serves this login for personal accounts — only Workspace/Standard works."))
            }
        }
        .formStyle(.grouped)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Picker(L("Язык", "Language"), selection: $settings.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }

            Picker(L("Оформление", "Appearance"), selection: $settings.appearance) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }

            Picker(L("Обновлять каждые", "Refresh every"), selection: $settings.refreshMinutes) {
                ForEach([1, 2, 5, 10, 15, 30], id: \.self) { minutes in
                    Text(L("\(minutes) мин", "\(minutes) min")).tag(minutes)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle(L("Обводка вокруг выреза (notch)", "Outline around the notch"), isOn: $settings.showNotchOutline)
                    .disabled(NotchOutlineController.notchScreen == nil)
                Text(NotchOutlineController.notchScreen == nil
                     ? L("На этом экране нет выреза.", "This display has no notch.")
                     : L("Линия вокруг выреза заполняется по первому лимиту первого сервиса в списке.",
                         "A line around the notch fills up with the first limit of the first service in the list."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(L("Запускать при входе в систему", "Launch at login"), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, wantsEnabled in
                    let isEnabled = SMAppService.mainApp.status == .enabled
                    guard wantsEnabled != isEnabled else { return }
                    do {
                        if wantsEnabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = isEnabled
                    }
                }

            Section {
                Button(L("Обновить сейчас", "Refresh now")) {
                    Task { await model.refresh() }
                }
                .disabled(model.isRefreshing)
                Text(L("Виджет на рабочем столе перерисовывается после каждого обновления, но macOS может откладывать перерисовку виджетов, пока они не на виду.",
                        "The desktop widget is redrawn after every refresh, but macOS may delay redrawing widgets while they are out of sight."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }
}

// MARK: - Notifications

private struct NotificationsTab: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var notifier: Notifier

    private static let thresholds = Array(stride(from: 50, through: 100, by: 5))

    private func providerThreshold(_ id: ProviderID) -> Binding<Int> {
        Binding(
            get: { settings.threshold(for: id) },
            set: { settings.providerThresholds[id] = $0 }
        )
    }

    var body: some View {
        Form {
            if notifier.authorization == .denied {
                Section {
                    Label(L("Уведомления для LimitsWatcher выключены в системных настройках.",
                            "Notifications for LimitsWatcher are turned off in System Settings."),
                          systemImage: "bell.slash")
                        .foregroundStyle(.orange)
                    Button(L("Открыть настройки уведомлений", "Open Notification Settings")) {
                        notifier.openSystemSettings()
                    }
                }
            }

            Section {
                Toggle(L("Предупреждать о высоком использовании", "Warn about high usage"), isOn: $settings.notifyUsage)

                if settings.notifyUsage {
                    Picker(L("Порог", "Threshold"), selection: $settings.separateThresholds) {
                        Text(L("Один для всех", "Same for all")).tag(false)
                        Text(L("Свой для каждого", "Per service")).tag(true)
                    }
                    .pickerStyle(.segmented)

                    if settings.separateThresholds {
                        ForEach(settings.order.filter { settings.enabled.contains($0) }) { id in
                            thresholdPicker(id.title, selection: providerThreshold(id))
                        }
                    } else {
                        thresholdPicker(L("Все сервисы", "All services"), selection: $settings.usageThreshold)
                    }
                }

                hint(L("Одно уведомление, когда любой лимит сервиса (сессия, неделя…) доходит до порога. Следующее — только после сброса этого лимита.",
                       "One notification when any of a service's limits (session, week…) reaches the threshold. The next one only after that limit resets."))
            }

            Section {
                Toggle(L("Сообщать о сбросе лимита", "Tell me when a limit resets"), isOn: $settings.notifyReset)
                hint(L("Приходит точно ко времени сброса, если лимит успели потратить хотя бы на 1%.",
                       "Arrives right at the reset time, for limits that were used at least 1%."))
            }

            Section {
                Button(L("Отправить тестовое уведомление", "Send a test notification")) {
                    Task { await notifier.sendTest() }
                }
            }
        }
        .formStyle(.grouped)
        .task { await notifier.refreshAuthorization() }
    }

    private func thresholdPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(Self.thresholds, id: \.self) { value in
                Text("\(value)%").tag(value)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Diagnostics

private struct DiagnosticsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: ProviderID = .claude

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Сырые ответы эндпоинтов. Все они недокументированные: если проценты выглядят неправдоподобно или карточка пишет «формат мог измениться», сравните ответ с разбором в коде (App/Providers).",
                    "Raw endpoint responses. They are all undocumented: if the percentages look wrong or a card says the format may have changed, compare the response with the parsing code (App/Providers)."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Picker(L("Сервис", "Service"), selection: $selected) {
                    ForEach(ProviderID.allCases) { id in
                        Text(id.title).tag(id)
                    }
                }
                .frame(maxWidth: 260)

                Spacer()

                Button(L("Копировать", "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.raw[selected] ?? "", forType: .string)
                }
                .disabled(model.raw[selected] == nil)
            }

            if let message = model.signedOut[selected] {
                Label(L("Скрыт из меню и виджета: ", "Hidden from the menu and widget: ") + message, systemImage: "person.crop.circle.badge.xmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                Text(model.raw[selected] ?? L("Нет данных. Включите сервис и нажмите «Обновить».", "No data. Turn the service on and press Refresh."))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding()
    }
}
