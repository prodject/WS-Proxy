import Foundation
import CommonCrypto
import CryptoKit

enum MTProtoCryptoError: Error {
    case invalidKeyLength
    case invalidIVLength
    case cryptorCreationFailed
}

final class MTProtoStreamCipher {
    private let cryptor: CCCryptorRef
    private var counter: [UInt8]
    private var keystream = [UInt8](repeating: 0, count: 16)
    private var keystreamOffset = 16

    init(key: Data, iv: Data) throws {
        guard key.count == kCCKeySizeAES256 else {
            throw MTProtoCryptoError.invalidKeyLength
        }
        guard iv.count == kCCBlockSizeAES128 else {
            throw MTProtoCryptoError.invalidIVLength
        }

        var cryptorRef: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes in
            CCCryptorCreate(
                CCOperation(kCCEncrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionECBMode),
                keyBytes.baseAddress,
                key.count,
                nil,
                &cryptorRef
            )
        }
        guard status == kCCSuccess, let cryptorRef else {
            throw MTProtoCryptoError.cryptorCreationFailed
        }

        self.cryptor = cryptorRef
        self.counter = Array(iv)
    }

    deinit {
        CCCryptorRelease(cryptor)
    }

    func transform(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return data }

        var output = Data(count: data.count)
        try data.withUnsafeBytes { srcBytes in
            try output.withUnsafeMutableBytes { dstBytes in
                guard
                    let src = srcBytes.bindMemory(to: UInt8.self).baseAddress,
                    let dst = dstBytes.bindMemory(to: UInt8.self).baseAddress
                else {
                    return
                }

                for index in 0..<data.count {
                    if keystreamOffset >= keystream.count {
                        try generateKeystreamBlock()
                    }
                    dst[index] = src[index] ^ keystream[keystreamOffset]
                    keystreamOffset += 1
                }
            }
        }
        return output
    }

    private func generateKeystreamBlock() throws {
        var input = counter
        var output = [UInt8](repeating: 0, count: 16)
        var moved: size_t = 0
        let status = input.withUnsafeBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                CCCryptorUpdate(
                    cryptor,
                    inputBytes.baseAddress,
                    input.count,
                    outputBytes.baseAddress,
                    output.count,
                    &moved
                )
            }
        }
        guard status == kCCSuccess, moved == 16 else {
            throw MTProtoCryptoError.cryptorCreationFailed
        }
        keystream = output
        keystreamOffset = 0
        incrementCounter()
    }

    private func incrementCounter() {
        for index in stride(from: counter.count - 1, through: 0, by: -1) {
            counter[index] &+= 1
            if counter[index] != 0 {
                break
            }
        }
    }
}

struct MTProtoBridgeContext {
    let relayInit: Data
    private let clientDecryptor: MTProtoStreamCipher
    private let clientEncryptor: MTProtoStreamCipher
    private let relayEncryptor: MTProtoStreamCipher
    private let relayDecryptor: MTProtoStreamCipher
    private let packetSplitter: MTProtoPacketSplitter
    private let lock = NSLock()

    init(handshake: MTProtoHandshake, secretHex: String) throws {
        let secret = try Data(hexEncoded: secretHex)
        let clientInit = handshake.rawPacket
        let clientDecPrekey = clientInit.subdata(in: 8..<40)
        let clientDecIV = clientInit.subdata(in: 40..<56)
        let clientDecKey = Data(SHA256.hash(data: clientDecPrekey + secret))

        let clientEncPrekeyIV = Data(clientInit.subdata(in: 8..<56).reversed())
        let clientEncKey = Data(SHA256.hash(data: clientEncPrekeyIV.prefix(32) + secret))
        let clientEncIV = clientEncPrekeyIV.suffix(16)

        relayInit = try MTProtoRelayInitGenerator.make(
            transport: handshake.transport,
            dcIndex: handshake.isMedia ? -handshake.dcID : handshake.dcID
        )

        let relayEncKey = relayInit.subdata(in: 8..<40)
        let relayEncIV = relayInit.subdata(in: 40..<56)
        let relayDecPrekeyIV = Data(relayInit.subdata(in: 8..<56).reversed())
        let relayDecKey = relayDecPrekeyIV.prefix(32)
        let relayDecIV = relayDecPrekeyIV.suffix(16)

        clientDecryptor = try MTProtoStreamCipher(key: clientDecKey, iv: clientDecIV)
        clientEncryptor = try MTProtoStreamCipher(key: clientEncKey, iv: clientEncIV)
        relayEncryptor = try MTProtoStreamCipher(key: relayEncKey, iv: relayEncIV)
        relayDecryptor = try MTProtoStreamCipher(key: relayDecKey, iv: relayDecIV)
        packetSplitter = MTProtoPacketSplitter(
            inspectorCipher: MTProtoStreamCipher(key: relayEncKey, iv: relayEncIV),
            transport: handshake.transport
        )

        _ = try clientDecryptor.transform(Data(repeating: 0, count: 64))
        _ = try relayEncryptor.transform(Data(repeating: 0, count: 64))
    }

    func encodeClientChunk(_ data: Data) throws -> [Data] {
        try lock.withLock {
            let plain = try clientDecryptor.transform(data)
            let relayCipher = try relayEncryptor.transform(plain)
            return packetSplitter.split(relayCipher)
        }
    }

    func flushClientTail() throws -> [Data] {
        try lock.withLock {
            packetSplitter.flush()
        }
    }

    func decodeRelayChunk(_ data: Data) throws -> Data {
        try lock.withLock {
            let plain = try relayDecryptor.transform(data)
            return try clientEncryptor.transform(plain)
        }
    }
}

enum MTProtoRelayInitGenerator {
    private static let handshakeLength = 64
    private static let skipLength = 8
    private static let prekeyLength = 32
    private static let ivLength = 16
    private static let protoTagPos = 56
    private static let dcIdxPos = 60

    private static let reservedFirstBytes: Set<UInt8> = [0xEF]
    private static let reservedStarts: Set<Data> = [
        Data([0x48, 0x45, 0x41, 0x44]),
        Data([0x50, 0x4F, 0x53, 0x54]),
        Data([0x47, 0x45, 0x54, 0x20]),
        Data([0xEE, 0xEE, 0xEE, 0xEE]),
        Data([0xDD, 0xDD, 0xDD, 0xDD]),
        Data([0x16, 0x03, 0x01, 0x02])
    ]

    static func make(transport: MTProtoTransport, dcIndex: Int) throws -> Data {
        while true {
            let randomBytes = Data((0..<handshakeLength).map { _ in UInt8.random(in: .min ... .max) })
            guard isValidSeed(randomBytes) else { continue }

            let encKey = randomBytes.subdata(in: skipLength..<(skipLength + prekeyLength))
            let encIV = randomBytes.subdata(in: (skipLength + prekeyLength)..<(skipLength + prekeyLength + ivLength))
            let encryptor = try MTProtoStreamCipher(key: encKey, iv: encIV)
            let encryptedFull = try encryptor.transform(randomBytes)

            let dcValue = Int16(dcIndex).littleEndian
            let dcBytes = withUnsafeBytes(of: dcValue) { Data($0) }
            let tailPlain = transport.tagData + dcBytes + Data((0..<2).map { _ in UInt8.random(in: .min ... .max) })
            let keystreamTail = xor(encryptedFull.subdata(in: protoTagPos..<handshakeLength), randomBytes.subdata(in: protoTagPos..<handshakeLength))
            let encryptedTail = xor(tailPlain, keystreamTail)

            var result = randomBytes
            result.replaceSubrange(protoTagPos..<handshakeLength, with: encryptedTail)
            return result
        }
    }

    private static func isValidSeed(_ bytes: Data) -> Bool {
        guard bytes.count == handshakeLength else { return false }
        guard let first = bytes.first else { return false }
        if reservedFirstBytes.contains(first) {
            return false
        }
        if reservedStarts.contains(Data(bytes.prefix(4))) {
            return false
        }
        if bytes.subdata(in: 4..<8).allSatisfy({ $0 == 0 }) {
            return false
        }
        return true
    }

    private static func xor(_ lhs: Data, _ rhs: Data) -> Data {
        Data(zip(lhs, rhs).map { $0 ^ $1 })
    }
}

private extension Data {
    init(hexEncoded hex: String) throws {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count.isMultiple(of: 2) else {
            throw MTProtoCryptoError.invalidKeyLength
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            let byteString = cleaned[index..<next]
            guard let value = UInt8(byteString, radix: 16) else {
                throw MTProtoCryptoError.invalidKeyLength
            }
            bytes.append(value)
            index = next
        }
        self.init(bytes)
    }
}

private extension NSLock {
    func withLock<T>(_ work: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try work()
    }
}
