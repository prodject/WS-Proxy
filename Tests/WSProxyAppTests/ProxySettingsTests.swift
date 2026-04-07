import XCTest
@testable import WSProxy

final class ProxySettingsTests: XCTestCase {
    func testDefaultSettingsValidate() throws {
        try ProxySettings.default.validate()
    }

    func testParseDCMapping() throws {
        let mapping = try DCMapping.parse("2:149.154.167.220")
        XCTAssertEqual(mapping.dc, 2)
        XCTAssertEqual(mapping.ip, "149.154.167.220")
    }

    func testProxyURLBuilder() {
        let settings = ProxySettings.default
        let url = ProxyLinkBuilder.makeURL(from: settings)
        XCTAssertEqual(url?.scheme, "tg")
        XCTAssertEqual(url?.host, "proxy")
    }

    func testInvalidSecretThrows() {
        var settings = ProxySettings.default
        settings.secret = "abc"
        XCTAssertThrowsError(try settings.validate())
    }
}
