import Foundation
import Network

final class RawWebSocket {
    enum WebSocketError: Error {
        case emptyResponse
        case invalidHandshake(String)
        case closed
    }

    private let reader: AsyncByteStreamReader
    private let writer: NWConnection
    private var isClosed = false

    private init(reader: AsyncByteStreamReader, writer: NWConnection) {
        self.reader = reader
        self.writer = writer
    }

    static func connect(
        ip: String,
        domain: String,
        path: String = "/apiws",
        timeout: TimeInterval = 10
    ) async throws -> RawWebSocket {
        let nwHost = NWEndpoint.Host(ip)
        let parameters = NWParameters.tls
        parameters.allowLocalEndpointReuse = true

        let connection = NWConnection(host: nwHost, port: 443, using: parameters)
        connection.start(queue: .global(qos: .utility))
        try await waitUntilReady(connection, timeout: timeout)

        let wsKey = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        let request = """
        GET \(path) HTTP/1.1\r
        Host: \(domain)\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: \(wsKey)\r
        Sec-WebSocket-Version: 13\r
        Sec-WebSocket-Protocol: binary\r
        Origin: https://web.telegram.org\r
        User-Agent: Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148\r
        \r
        """

        try await send(connection: connection, data: Data(request.utf8))
        let response = try await readHTTPResponse(from: connection, timeout: timeout)
        let status = parseStatusCode(response)
        guard status == 101 else {
            throw WebSocketError.invalidHandshake(response)
        }

        return RawWebSocket(
            reader: AsyncByteStreamReader(connection: connection),
            writer: connection
        )
    }

    func send(_ data: Data) async throws {
        guard !isClosed else { throw WebSocketError.closed }
        let frame = Self.buildFrame(opcode: 0x2, data: data, mask: true)
        try await Self.sendData(connection: writer, data: frame)
    }

    func sendBatch(_ parts: [Data]) async throws {
        guard !isClosed else { throw WebSocketError.closed }
        for part in parts {
            let frame = Self.buildFrame(opcode: 0x2, data: part, mask: true)
            try await Self.sendData(connection: writer, data: frame)
        }
    }

    func recv() async throws -> Data? {
        while !isClosed {
            let (opcode, payload) = try await readFrame()

            switch opcode {
            case 0x8:
                isClosed = true
                try? await Self.sendData(connection: writer, data: Self.buildFrame(opcode: 0x8, data: payload.prefix(2), mask: true))
                writer.cancel()
                return nil
            case 0x9:
                try? await Self.sendData(connection: writer, data: Self.buildFrame(opcode: 0xA, data: payload, mask: true))
                continue
            case 0xA:
                continue
            case 0x1, 0x2:
                return payload
            default:
                continue
            }
        }
        return nil
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        try? await Self.sendData(connection: writer, data: Self.buildFrame(opcode: 0x8, data: Data(), mask: true))
        writer.cancel()
    }

    private func readFrame() async throws -> (UInt8, Data) {
        let header = try await reader.readExactly(2)
        let opcode = header[0] & 0x0F
        var payloadLength = Int(header[1] & 0x7F)
        if payloadLength == 126 {
            let ext = try await reader.readExactly(2)
            payloadLength = Int(ext[0]) << 8 | Int(ext[1])
        } else if payloadLength == 127 {
            let ext = try await reader.readExactly(8)
            payloadLength = ext.reduce(0) { ($0 << 8) | Int($1) }
        }

        let masked = (header[1] & 0x80) != 0
        let maskKey = masked ? try await reader.readExactly(4) : Data()
        let payload = payloadLength > 0 ? try await reader.readExactly(payloadLength) : Data()
        if masked {
            return (opcode, xor(payload, maskKey))
        }
        return (opcode, payload)
    }

    private static func waitUntilReady(_ connection: NWConnection, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch connection.state {
            case .ready:
                return
            case .failed(let error):
                throw error
            case .cancelled:
                throw WebSocketError.closed
            default:
                if Date() >= deadline {
                    throw WebSocketError.closed
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private static func sendData(connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func readHTTPResponse(from connection: NWConnection, timeout: TimeInterval) async throws -> String {
        let reader = AsyncByteStreamReader(connection: connection)
        var bytes = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while !bytes.containsCRLFCRLF {
            if Date() >= deadline {
                throw WebSocketError.emptyResponse
            }
            let chunk = try await reader.readChunk(maxLength: 512)
            guard !chunk.isEmpty else { throw WebSocketError.emptyResponse }
            bytes.append(chunk)
            if bytes.count > 16_384 {
                break
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func parseStatusCode(_ response: String) -> Int {
        guard let line = response.components(separatedBy: "\r\n").first else { return 0 }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return 0 }
        return Int(parts[1]) ?? 0
    }

    private static func buildFrame(opcode: UInt8, data: Data, mask: Bool) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode)
        let length = data.count
        if mask {
            if length < 126 {
                frame.append(0x80 | UInt8(length))
            } else if length < 65_536 {
                frame.append(0x80 | 126)
                var ext = UInt16(length).bigEndian
                frame.append(Data(bytes: &ext, count: MemoryLayout<UInt16>.size))
            } else {
                frame.append(0x80 | 127)
                var ext = UInt64(length).bigEndian
                frame.append(Data(bytes: &ext, count: MemoryLayout<UInt64>.size))
            }
            let maskKey = Data((0..<4).map { _ in UInt8.random(in: .min ... .max) })
            frame.append(maskKey)
            frame.append(xor(data, maskKey))
        } else {
            if length < 126 {
                frame.append(UInt8(length))
            } else if length < 65_536 {
                frame.append(126)
                var ext = UInt16(length).bigEndian
                frame.append(Data(bytes: &ext, count: MemoryLayout<UInt16>.size))
            } else {
                frame.append(127)
                var ext = UInt64(length).bigEndian
                frame.append(Data(bytes: &ext, count: MemoryLayout<UInt64>.size))
            }
            frame.append(data)
        }
        return frame
    }

    private static func xor(_ data: Data, _ maskKey: Data) -> Data {
        let mask = Array(maskKey)
        return Data(data.enumerated().map { index, byte in
            byte ^ mask[index % mask.count]
        })
    }
}

private extension Data {
    var containsCRLFCRLF: Bool {
        range(of: Data([13, 10, 13, 10])) != nil
    }
}

final class AsyncByteStreamReader {
    private let connection: NWConnection
    private var buffer = Data()
    private var isFinished = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func readExactly(_ count: Int) async throws -> Data {
        while buffer.count < count {
            let chunk = try await readChunk(maxLength: max(1, count - buffer.count))
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)
        }
        guard buffer.count >= count else {
            throw RawWebSocket.WebSocketError.closed
        }
        let prefix = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(prefix)
    }

    func readChunk(maxLength: Int) async throws -> Data {
        if !buffer.isEmpty {
            let chunk = buffer.prefix(min(maxLength, buffer.count))
            buffer.removeFirst(chunk.count)
            return Data(chunk)
        }
        guard !isFinished else { return Data() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: maxLength
            ) { [weak self] data, _, isComplete, error in
                guard let self else {
                    continuation.resume(returning: Data())
                    return
                }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if isComplete {
                    self.isFinished = true
                }
                continuation.resume(returning: data ?? Data())
            }
        }
    }
}
