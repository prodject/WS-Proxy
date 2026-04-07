import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var settings: ProxySettings
    @Published private(set) var engineStatus: ProxyEngineStatus = .stopped
    @Published private(set) var lastMessage: String?

    private let settingsStore: SettingsStore
    private let engine: ProxyEngine

    init(
        settingsStore: SettingsStore,
        engine: ProxyEngine = LocalProxyEngine()
    ) {
        self.settingsStore = settingsStore
        self.engine = engine
        self.settings = settingsStore.load()
    }

    func save() {
        do {
            try settingsStore.save(settings)
            lastMessage = "Settings saved"
        } catch {
            lastMessage = "Failed to save settings: \(error.localizedDescription)"
        }
    }

    func setMessage(_ message: String) {
        lastMessage = message
    }

    func resetToDefaults() {
        settings = .default
        save()
    }

    func startProxy() async {
        do {
            try settings.validate()
            try await engine.start(with: settings)
            engineStatus = .running
            lastMessage = "Proxy started"
        } catch {
            engineStatus = .failed(error.localizedDescription)
            lastMessage = "Proxy start failed: \(error.localizedDescription)"
        }
    }

    func stopProxy() async {
        do {
            try await engine.stop()
            engineStatus = .stopped
            lastMessage = "Proxy stopped"
        } catch {
            engineStatus = .failed(error.localizedDescription)
            lastMessage = "Proxy stop failed: \(error.localizedDescription)"
        }
    }

    var generatedProxyURL: URL? {
        ProxyLinkBuilder.makeURL(from: settings)
    }
}
