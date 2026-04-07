import CryptoKit
import XCTest
@testable import WSProxy

final class MTProtoHandshakeParserTests: XCTestCase {
    func testParseAbrdgedHandshake() {
        let secretHex = "00112233445566778899aabbccddeeff"
        let packet = try! makeHandshakePacket(
            secretHex: secretHex,
            transport: .abridged,
            dcID: 2,
            isMedia: false
        )
        let handshake = MTProtoHandshakeParser.parse(packet, secretHex: secretHex)

        XCTAssertEqual(handshake?.transport, .abridged)
        XCTAssertEqual(handshake?.dcID, 2)
        XCTAssertEqual(handshake?.isMedia, false)
    }

    func testRejectInvalidTransportTail() {
        let secretHex = "00112233445566778899aabbccddeeff"
        let packet = try! makeHandshakePacket(
            secretHex: secretHex,
            transportTag: Data([0x12, 0x34, 0x56, 0x78]),
            dcID: 2
        )

        XCTAssertNil(MTProtoHandshakeParser.parse(packet, secretHex: secretHex))
        XCTAssertTrue(MTProtoHandshakeParser.isLikelyHandshake(packet))
    }

    private func makeHandshakePacket(
        secretHex: String,
        transport: MTProtoTransport,
        dcID: Int,
        isMedia: Bool
    ) throws -> Data {
        let dcValue = Int16(isMedia ? -dcID : dcID).littleEndian
        let dcBytes = withUnsafeBytes(of: dcValue) { Data($0) }
        return try makeHandshakePacket(
            secretHex: secretHex,
            transportTag: transport.tagData,
            dcBytes: dcBytes
        )
    }

    private func makeHandshakePacket(
        secretHex: String,
        transportTag: Data,
        dcBytes: Data
    ) throws -> Data {
        let cleaned = secretHex.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretBytes = stride(from: 0, to: cleaned.count, by: 2).map { offset -> UInt8 in
            let start = cleaned.index(cleaned.startIndex, offsetBy: offset)
            let end = cleaned.index(start, offsetBy: 2)
            return UInt8(cleaned[start..<end], radix: 16)!
        }
        let secret = Data(secretBytes)

        var packet = Data((0..<64).map { _ in UInt8.random(in: .min ... .max) })
        let prekey = packet.subdata(in: 8..<40)
        let iv = packet.subdata(in: 40..<56)
        let key = Data(SHA256.hash(data: prekey + secret))
        let encryptor = try MTProtoStreamCipher(key: key, iv: iv)

        let tailPlain = transportTag + dcBytes + Data([0xAA, 0xBB])
        packet.replaceSubrange(56..<64, with: tailPlain)
        return try encryptor.transform(packet)
    }
}
