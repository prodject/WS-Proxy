import Foundation
import CryptoKit

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

    static func parse(_ packet: Data, secretHex: String) -> MTProtoHandshake? {
        guard packet.count == handshakeLength else { return nil }

        guard let secret = secretData(from: secretHex) else {
            return nil
        }
        let prekey = packet.subdata(in: 8..<40)
        let iv = packet.subdata(in: 40..<56)
        let key = Data(SHA256.hash(data: prekey + secret))
        guard let cipher = try? MTProtoStreamCipher(key: key, iv: iv) else {
            return nil
        }

        guard let decrypted = try? cipher.transform(packet) else {
            return nil
        }
        guard decrypted.count == handshakeLength else { return nil }
        guard let transport = MTProtoTransport(tagBytes: decrypted.subdata(in: 56..<60)) else {
            return nil
        }

        let dcBytes = decrypted.subdata(in: 60..<62)
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

    private static func secretData(from secretHex: String) -> Data? {
        let cleaned = secretHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count == 32, cleaned.count.isMultiple(of: 2) else {
            return nil
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let value = UInt8(cleaned[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(value)
            index = next
        }
        return Data(bytes)
    }
}
