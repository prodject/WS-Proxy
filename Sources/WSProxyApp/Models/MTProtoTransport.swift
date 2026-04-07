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

    var tagData: Data {
        var value = UInt32(self.rawValue).bigEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
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

        let key = packet.subdata(in: 8..<40)
        let iv = packet.subdata(in: 40..<56)
        guard let cipher = try? MTProtoStreamCipher(key: key, iv: iv) else {
            return nil
        }

        guard let tail = try? cipher.transform(packet.subdata(in: 56..<64)) else {
            return nil
        }
        guard tail.count == 8 else { return nil }
        guard let transport = MTProtoTransport(tagBytes: tail.prefix(4)) else {
            return nil
        }

        let dcBytes = tail.subdata(in: 4..<6)
        let dcIndex = Int16(bitPattern: UInt16(dcBytes[0]) | (UInt16(dcBytes[1]) << 8))

        return MTProtoHandshake(
            transport: transport,
            dcID: Int(abs(dcIndex)),
            isMedia: dcIndex < 0,
            rawPacket: packet
        )
    }

    static func isLikelyHandshake(_ packet: Data) -> Bool {
        packet.count == handshakeLength
    }
}
