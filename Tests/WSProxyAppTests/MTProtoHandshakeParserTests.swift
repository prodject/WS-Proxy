import XCTest
@testable import WSProxy

final class MTProtoHandshakeParserTests: XCTestCase {
    func testParseAbrdgedHandshake() {
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

        let packet = Data(bytes)
        let handshake = MTProtoHandshakeParser.parse(packet)

        XCTAssertEqual(handshake?.transport, .abridged)
        XCTAssertEqual(handshake?.dcID, 2)
        XCTAssertEqual(handshake?.isMedia, false)
    }

    func testRejectReservedHeader() {
        var bytes = [UInt8](repeating: 0x11, count: 64)
        bytes[0] = 0xEF
        let packet = Data(bytes)

        XCTAssertNil(MTProtoHandshakeParser.parse(packet))
        XCTAssertFalse(MTProtoHandshakeParser.isLikelyHandshake(packet))
    }
}
