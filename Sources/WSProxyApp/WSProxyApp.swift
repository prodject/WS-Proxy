import SwiftUI

@main
struct WSProxyApp: App {
    @StateObject private var appState = AppState(
        settingsStore: SettingsStore()
    )

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(appState.logStore)
        }
    }
}
