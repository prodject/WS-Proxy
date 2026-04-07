import XCTest
@testable import WSProxy

final class SettingsStoreTests: XCTestCase {
    func testSaveAndLoadRoundTrip() throws {
        let suiteName = "wsproxy.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        var settings = ProxySettings.default
        settings.host = "127.0.0.1"
        settings.port = 9050

        try store.save(settings)
        let loaded = store.load()

        XCTAssertEqual(loaded.host, settings.host)
        XCTAssertEqual(loaded.port, settings.port)
        XCTAssertEqual(loaded.dcIP, settings.dcIP)
    }
}
