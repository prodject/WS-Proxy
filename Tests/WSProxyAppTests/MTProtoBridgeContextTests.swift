import XCTest
@testable import WSProxy

final class MTProtoBridgeContextTests: XCTestCase {
    func testBridgeContextBuildsRelayInit() throws {
        let packet = try MTProtoRelayInitGenerator.make(
            transport: .abridged,
            dcIndex: 2
        )
        let handshake = MTProtoHandshakeParser.parse(packet)
        XCTAssertNotNil(handshake)

        let context = try MTProtoBridgeContext(
            handshake: handshake!,
            secretHex: "00112233445566778899aabbccddeeff"
        )

        XCTAssertEqual(context.relayInit.count, 64)
    }
}
