import Foundation

final class MTProtoPacketSplitter {
    private let transport: MTProtoTransport
    private let inspectorCipher: MTProtoStreamCipher
    private var cipherBuffer = Data()
    private var plainBuffer = Data()
    private var isDisabled = false
    private let lock = NSLock()

    init(inspectorCipher: MTProtoStreamCipher, transport: MTProtoTransport) {
        self.inspectorCipher = inspectorCipher
        self.transport = transport
        try? self.inspectorCipher.transform(Data(repeating: 0, count: 64))
    }

    func split(_ chunk: Data) -> [Data] {
        guard !chunk.isEmpty else { return [] }
        return lock.withLock {
            if isDisabled {
                return [chunk]
            }

            cipherBuffer.append(chunk)
            guard let plain = try? inspectorCipher.transform(chunk) else {
                isDisabled = true
                let tail = cipherBuffer
                cipherBuffer.removeAll(keepingCapacity: true)
                plainBuffer.removeAll(keepingCapacity: true)
                return [tail]
            }
            plainBuffer.append(plain)

            var packets: [Data] = []
            while !cipherBuffer.isEmpty {
                guard let length = nextPacketLength() else { break }
                if length <= 0 {
                    packets.append(cipherBuffer)
                    cipherBuffer.removeAll(keepingCapacity: true)
                    plainBuffer.removeAll(keepingCapacity: true)
                    isDisabled = true
                    break
                }

                guard cipherBuffer.count >= length else { break }
                packets.append(cipherBuffer.prefix(length))
                cipherBuffer.removeFirst(length)
                plainBuffer.removeFirst(length)
            }
            return packets
        }
    }

    func flush() -> [Data] {
        lock.withLock {
            guard !cipherBuffer.isEmpty else { return [] }
            let tail = cipherBuffer
            cipherBuffer.removeAll(keepingCapacity: true)
            plainBuffer.removeAll(keepingCapacity: true)
            return [tail]
        }
    }

    private func nextPacketLength() -> Int? {
        switch transport {
        case .abridged:
            return nextAbridgedLength()
        case .intermediate, .paddedIntermediate:
            return nextIntermediateLength()
        }
    }

    private func nextAbridgedLength() -> Int? {
        guard let first = plainBuffer.first else { return nil }
        if first == 0x7F || first == 0xFF {
            guard plainBuffer.count >= 4 else { return nil }
            let payloadLength = Int(plainBuffer[1]) | (Int(plainBuffer[2]) << 8) | (Int(plainBuffer[3]) << 16)
            let packetLength = 4 + (payloadLength * 4)
            return packetLength > 0 ? packetLength : 0
        }
        let payloadLength = Int(first & 0x7F) * 4
        let packetLength = 1 + payloadLength
        return packetLength > 0 ? packetLength : 0
    }

    private func nextIntermediateLength() -> Int? {
        guard plainBuffer.count >= 4 else { return nil }
        let length = Int(plainBuffer[0])
            | (Int(plainBuffer[1]) << 8)
            | (Int(plainBuffer[2]) << 16)
            | (Int(plainBuffer[3]) << 24)
        let payloadLength = length & 0x7FFF_FFFF
        let packetLength = 4 + payloadLength
        return packetLength > 0 ? packetLength : 0
    }
}
