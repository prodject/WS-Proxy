import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var settings: ProxySettings
    @Published private(set) var engineStatus: ProxyEngineStatus = .stopped
    @Published private(set) var lastMessage: String?
    @Published private(set) var updateStatus: AppUpdateStatus = .idle
    @Published var availableUpdate: AppUpdateInfo?
    let logStore: ProxyLogStore

    private let settingsStore: SettingsStore
    private let engine: ProxyEngine
    private let updateChecker: AppUpdateChecker
    private var didRunAutomaticUpdateCheck = false

    init(
        settingsStore: SettingsStore,
        logStore: ProxyLogStore = ProxyLogStore(),
        engine: ProxyEngine = LocalProxyEngine(),
        updateChecker: AppUpdateChecker = AppUpdateChecker()
    ) {
        self.settingsStore = settingsStore
        self.logStore = logStore
        self.engine = engine
        self.updateChecker = updateChecker
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

    func checkForUpdatesIfNeeded() async {
        guard settings.checkUpdates, !didRunAutomaticUpdateCheck else { return }
        didRunAutomaticUpdateCheck = true
        await refreshUpdates(force: false)
    }

    func refreshUpdates(force: Bool) async {
        updateStatus = .checking
        let status = await updateChecker.checkForUpdates(
            currentVersion: AppReleaseVersion.current(),
            force: force
        )
        updateStatus = status
        if case .updateAvailable(let info) = status {
            availableUpdate = info
            logStore.append(.info, "Update available: \(info.latestVersion)")
        } else if case .failed(let message) = status {
            logStore.append(.warning, "Update check failed: \(message)")
        }
    }
}
