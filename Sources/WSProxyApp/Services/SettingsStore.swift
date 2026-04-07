import Foundation

final class SettingsStore {
    private let key = "wsproxy.settings"
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> ProxySettings {
        guard let data = defaults.data(forKey: key) else {
            return .default
        }
        do {
            return try decoder.decode(ProxySettings.self, from: data)
        } catch {
            return .default
        }
    }

    func save(_ settings: ProxySettings) throws {
        let data = try encoder.encode(settings)
        defaults.set(data, forKey: key)
    }
}
