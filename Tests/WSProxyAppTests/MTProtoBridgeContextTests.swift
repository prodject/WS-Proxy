import XCTest
@testable import WSProxy

final class MTProtoBridgeContextTests: XCTestCase {
    func testBridgeContextBuildsRelayInit() throws {
        var bytes = [UInt8](repeating: 0x11, count: 64)
        bytes[0] = 0x01
        bytes[4] = 0x02
        bytes[5] = 0x03
        bytes[6] = 0x04
        bytes[7] = 0x05
        bytes[56] = 0xEF
        bytes[57] = 0xEF
        bytes[58] = 0xEF
        bytes[59] = 0xEF
        bytes[60] = 0x02
        bytes[61] = 0x00

        let handshake = MTProtoHandshakeParser.parse(Data(bytes))
        XCTAssertNotNil(handshake)

        let context = try MTProtoBridgeContext(
            handshake: handshake!,
            secretHex: "00112233445566778899aabbccddeeff"
        )

        XCTAssertEqual(context.relayInit.count, 64)
    }
}
