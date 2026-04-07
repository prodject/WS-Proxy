import XCTest
@testable import WSProxy

final class MTProtoPacketSplitterTests: XCTestCase {
    func testIntermediateSplitterKeepsWholePacket() {
        let splitter = MTProtoPacketSplitter(transport: .intermediate)
        var packet = Data([4, 0, 0, 0, 9, 8, 7, 6])

        let parts = splitter.split(packet)

        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0], packet)
    }

    func testFlushReturnsTail() {
        let splitter = MTProtoPacketSplitter(transport: .abridged)
        let tail = splitter.split(Data([0x01, 0x02]))
        XCTAssertNotNil(tail)
        XCTAssertEqual(splitter.flush().count, 1)
    }
}
