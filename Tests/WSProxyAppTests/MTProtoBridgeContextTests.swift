import CryptoKit
import XCTest
@testable import WSProxy

final class MTProtoBridgeContextTests: XCTestCase {
    func testBridgeContextBuildsRelayInit() throws {
        let secretHex = "00112233445566778899aabbccddeeff"
        let packet = try makeHandshakePacket(
            secretHex: secretHex,
            transportTag: MTProtoTransport.abridged.tagData,
            dcBytes: withUnsafeBytes(of: Int16(2).littleEndian) { Data($0) }
        )
        let handshake = MTProtoHandshakeParser.parse(packet, secretHex: secretHex)
        XCTAssertNotNil(handshake)

        let context = try MTProtoBridgeContext(
            handshake: handshake!,
            secretHex: secretHex
        )

        XCTAssertEqual(context.relayInit.count, 64)
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
