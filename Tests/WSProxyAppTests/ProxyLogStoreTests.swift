import XCTest
@testable import WSProxy

final class ProxyLogStoreTests: XCTestCase {
    func testLogStoreTrimsOldEntries() {
        let store = ProxyLogStore(maxEntries: 3)
        store.append(.info, "one")
        store.append(.info, "two")
        store.append(.info, "three")
        store.append(.info, "four")

        XCTAssertEqual(store.entries.count, 3)
        XCTAssertEqual(store.entries.map(\.message), ["two", "three", "four"])
    }

    func testSeedAddsDefaultEntriesOnce() {
        let store = ProxyLogStore(maxEntries: 10)
        store.seedWithPlaceholder()
        store.seedWithPlaceholder()

        XCTAssertEqual(store.entries.count, 2)
    }
}
