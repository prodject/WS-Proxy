import XCTest
@testable import WSProxy

final class MTProtoRelayInitGeneratorTests: XCTestCase {
    func testRelayInitHasExpectedLength() throws {
        let initPacket = try MTProtoRelayInitGenerator.make(
            transport: .abridged,
            dcIndex: 2
        )

        XCTAssertEqual(initPacket.count, 64)
    }
}
