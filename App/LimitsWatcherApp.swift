import SwiftUI

@main
struct LimitsWatcherApp: App {
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(model)
                .environment(\.locale, Loc.locale)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                if let text = model.menuBarText {
                    Text(text)
                }
            }
        }
        .menuBarExtraStyle(.window)

        Window(L("Настройки LimitsWatcher", "LimitsWatcher Settings"), id: "settings") {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .environment(\.locale, Loc.locale)
        }
        .windowResizability(.contentSize)
    }
}
