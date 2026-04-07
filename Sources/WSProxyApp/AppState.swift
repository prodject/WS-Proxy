import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var settings: ProxySettings
    @Published private(set) var engineStatus: ProxyEngineStatus = .stopped
    @Published private(set) var lastMessage: String?
    let logStore: ProxyLogStore

    private let settingsStore: SettingsStore
    private let engine: ProxyEngine

    init(
        settingsStore: SettingsStore,
        logStore: ProxyLogStore = ProxyLogStore(),
        engine: ProxyEngine = LocalProxyEngine()
    ) {
        self.settingsStore = settingsStore
        self.logStore = logStore
        self.engine = engine
        self.settings = settingsStore.load()
        self.logStore.seedWithPlaceholder()
    }

    func save() {
        do {
            try settingsStore.save(settings)
            lastMessage = "Settings saved"
            logStore.append(.info, "Settings saved")
        } catch {
            lastMessage = "Failed to save settings: \(error.localizedDescription)"
            logStore.append(.error, "Failed to save settings: \(error.localizedDescription)")
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
            logStore.append(.info, "Starting proxy engine")
            try await engine.start(with: settings, logger: logStore)
            engineStatus = .running
            lastMessage = "Proxy started"
        } catch {
            engineStatus = .failed(error.localizedDescription)
            lastMessage = "Proxy start failed: \(error.localizedDescription)"
            logStore.append(.error, "Proxy start failed: \(error.localizedDescription)")
        }
    }

    func stopProxy() async {
        do {
            logStore.append(.info, "Stopping proxy engine")
            try await engine.stop(logger: logStore)
            engineStatus = .stopped
            lastMessage = "Proxy stopped"
        } catch {
            engineStatus = .failed(error.localizedDescription)
            lastMessage = "Proxy stop failed: \(error.localizedDescription)"
            logStore.append(.error, "Proxy stop failed: \(error.localizedDescription)")
        }
    }

    var generatedProxyURL: URL? {
        ProxyLinkBuilder.makeURL(from: settings)
    }
}
