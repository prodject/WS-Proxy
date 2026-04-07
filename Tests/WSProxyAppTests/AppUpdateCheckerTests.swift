import Foundation
import XCTest
@testable import WSProxy

final class AppUpdateCheckerTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testReleaseVersionComparesBuildAndAttempt() {
        XCTAssertLessThan(
            AppReleaseVersion(rawValue: "v0.1.0-build9-a1"),
            AppReleaseVersion(rawValue: "v0.1.0-build10-a1")
        )
        XCTAssertLessThan(
            AppReleaseVersion(rawValue: "v0.1.0-build9-a1"),
            AppReleaseVersion(rawValue: "v0.1.0-build9-a2")
        )
    }

    func testCheckerReturnsDirectIPAWhenReleaseHasNewerBuild() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let suiteName = "wsproxy.update.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            let body = """
            {
              "tag_name": "v0.1.0-build9-a1",
              "html_url": "https://github.com/prodject/WS-Proxy/releases/tag/v0.1.0-build9-a1",
              "assets": [
                {
                  "name": "WSProxy-0.1.0+9.1.ipa",
                  "browser_download_url": "https://github.com/prodject/WS-Proxy/releases/download/v0.1.0-build9-a1/WSProxy-0.1.0+9.1.ipa"
                }
              ]
            }
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["ETag": "\"release-1\""]
            )!
            return (response, Data(body.utf8))
        }

        let checker = AppUpdateChecker(session: session, defaults: defaults, minimumCheckInterval: 3600)
        let status = await checker.checkForUpdates(
            currentVersion: AppReleaseVersion(rawValue: "v0.1.0-build1-a1"),
            force: true
        )

        guard case .updateAvailable(let info) = status else {
            return XCTFail("Expected updateAvailable, got \(status)")
        }

        XCTAssertEqual(info.latestVersion, "v0.1.0-build9-a1")
        XCTAssertEqual(
            info.downloadURL?.absoluteString,
            "https://github.com/prodject/WS-Proxy/releases/download/v0.1.0-build9-a1/WSProxy-0.1.0+9.1.ipa"
        )
    }
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
