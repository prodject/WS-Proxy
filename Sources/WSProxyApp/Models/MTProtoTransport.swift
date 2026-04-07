import Foundation

enum MTProtoTransport: Int, CaseIterable, Codable {
    case abridged = 0xEFEFEFEF
    case intermediate = 0xEEEEEEEE
    case paddedIntermediate = 0xDDDDDDDD

    var label: String {
        switch self {
        case .abridged:
            return "abridged"
        case .intermediate:
            return "intermediate"
        case .paddedIntermediate:
            return "padded-intermediate"
        }
    }

    init?(tagBytes: Data) {
        guard tagBytes.count >= 4 else { return nil }
        let value = tagBytes.prefix(4).reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        self.init(rawValue: Int(value))
    }
}

struct MTProtoHandshake: Equatable {
    let transport: MTProtoTransport
    let dcID: Int
    let isMedia: Bool
    let rawPacket: Data
}

enum MTProtoHandshakeParser {
    static let handshakeLength = 64

    static func parse(_ packet: Data) -> MTProtoHandshake? {
        guard packet.count == handshakeLength else { return nil }
        guard isLikelyHandshake(packet) else { return nil }

        let tagRange = 56..<60
        let dcRange = 60..<62
        guard let transport = MTProtoTransport(tagBytes: packet.subdata(in: tagRange)) else {
            return nil
        }

        let dcBytes = packet.subdata(in: dcRange)
        guard dcBytes.count == 2 else { return nil }
        let dcIndex = Int16(bitPattern: UInt16(dcBytes[0]) | (UInt16(dcBytes[1]) << 8))

        return MTProtoHandshake(
            transport: transport,
            dcID: Int(abs(dcIndex)),
            isMedia: dcIndex < 0,
            rawPacket: packet
        )
    }

    static func isLikelyHandshake(_ packet: Data) -> Bool {
        guard packet.count == handshakeLength else { return false }
        guard let first = packet.first else { return false }

        let reservedFirstBytes: Set<UInt8> = [0xEF]
        let reservedStarts: [Data] = [
            Data([0x48, 0x45, 0x41, 0x44]),
            Data([0x50, 0x4F, 0x53, 0x54]),
            Data([0x47, 0x45, 0x54, 0x20]),
            Data([0xEE, 0xEE, 0xEE, 0xEE]),
            Data([0xDD, 0xDD, 0xDD, 0xDD]),
            Data([0x16, 0x03, 0x01, 0x02])
        ]

        if reservedFirstBytes.contains(first) {
            return false
        }
        if reservedStarts.contains(Data(packet.prefix(4))) {
            return false
        }
        if packet[4...7].allSatisfy({ $0 == 0 }) {
            return false
        }
        return true
    }
}
