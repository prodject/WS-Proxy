import XCTest
@testable import WSProxy

final class MTProtoPacketSplitterTests: XCTestCase {
    func testIntermediateSplitterKeepsWholePacket() throws {
        let key = Data(repeating: 0x01, count: 32)
        let iv = Data(repeating: 0x02, count: 16)
        let encryptor = try MTProtoStreamCipher(key: key, iv: iv)
        let inspector = try MTProtoStreamCipher(key: key, iv: iv)
        let splitter = MTProtoPacketSplitter(inspectorCipher: inspector, transport: .intermediate)

        let plainPacket = Data([4, 0, 0, 0, 9, 8, 7, 6])
        let encryptedPacket = try encryptor.transform(plainPacket)

        let parts = splitter.split(encryptedPacket)

        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0], encryptedPacket)
    }

    func testFlushReturnsTail() throws {
        let key = Data(repeating: 0x01, count: 32)
        let iv = Data(repeating: 0x02, count: 16)
        let encryptor = try MTProtoStreamCipher(key: key, iv: iv)
        let inspector = try MTProtoStreamCipher(key: key, iv: iv)
        let splitter = MTProtoPacketSplitter(inspectorCipher: inspector, transport: .abridged)

        let encryptedTail = try encryptor.transform(Data([0x01, 0x02]))
        _ = splitter.split(encryptedTail)

        XCTAssertEqual(splitter.flush().count, 1)
    }
}
