import XCTest
@testable import WSProxy

final class MTProtoHandshakeParserTests: XCTestCase {
    func testParseAbrdgedHandshake() {
        let packet = try! makeHandshakePacket(
            transport: .abridged,
            dcID: 2,
            isMedia: false
        )
        let handshake = MTProtoHandshakeParser.parse(packet)

        XCTAssertEqual(handshake?.transport, .abridged)
        XCTAssertEqual(handshake?.dcID, 2)
        XCTAssertEqual(handshake?.isMedia, false)
    }

    func testRejectInvalidTransportTail() {
        let packet = try! makeHandshakePacket(
            transportTag: Data([0x12, 0x34, 0x56, 0x78]),
            dcID: 2
        )

        XCTAssertNil(MTProtoHandshakeParser.parse(packet))
        XCTAssertTrue(MTProtoHandshakeParser.isLikelyHandshake(packet))
    }

    private func makeHandshakePacket(
        transport: MTProtoTransport,
        dcID: Int,
        isMedia: Bool
    ) throws -> Data {
        let dcValue = Int16(isMedia ? -dcID : dcID).littleEndian
        let dcBytes = withUnsafeBytes(of: dcValue) { Data($0) }
        return try makeHandshakePacket(
            transportTag: transport.tagData,
            dcBytes: dcBytes
        )
    }

    private func makeHandshakePacket(transportTag: Data, dcBytes: Data) throws -> Data {
        let key = Data(repeating: 0x11, count: 32)
        let iv = Data(repeating: 0x22, count: 16)
        let encryptor = try MTProtoStreamCipher(key: key, iv: iv)

        var packet = Data((0..<64).map { _ in UInt8.random(in: .min ... .max) })
        packet.replaceSubrange(8..<40, with: key)
        packet.replaceSubrange(40..<56, with: iv)

        let tailPlain = transportTag + dcBytes + Data([0xAA, 0xBB])
        let encryptedTail = try encryptor.transform(tailPlain)
        packet.replaceSubrange(56..<64, with: encryptedTail)
        return packet
    }
}
