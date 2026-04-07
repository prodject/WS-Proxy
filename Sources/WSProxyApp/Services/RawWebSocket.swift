import Foundation
import Network

final class RawWebSocket {
    enum WebSocketError: Error {
        case emptyResponse
        case invalidHandshake(String)
        case closed
    }

    private let writer: NWConnection
    private var isClosed = false

    private init(writer: NWConnection) {
        self.writer = writer
    }

    static func connect(
        ip: String,
        domain: String,
        path: String = "/apiws",
        timeout: TimeInterval = 10
    ) async throws -> RawWebSocket {
        let nwEndpoint = NWEndpoint.Host(ip)

        let parameters = NWParameters.tls
        parameters.allowLocalEndpointReuse = true
        let connection = NWConnection(host: nwEndpoint, port: 443, using: parameters)
        connection.stateUpdateHandler = { _ in }
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

        try await sendHTTP(connection: connection, request: request)
        let response = try await readHTTPResponse(from: connection, timeout: timeout)
        let status = parseStatusCode(response)
        if status == 101 {
            return RawWebSocket(writer: connection)
        }

        throw WebSocketError.invalidHandshake(response)
    }

    func send(_ data: Data) async throws {
        guard !isClosed else { throw WebSocketError.closed }
        let frame = Self.buildFrame(opcode: 0x2, data: data, mask: true)
        try await send(connection: writer, data: frame)
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        let frame = Self.buildFrame(opcode: 0x8, data: Data(), mask: true)
        try? await send(connection: writer, data: frame)
        writer.cancel()
    }

    private static func waitUntilReady(_ connection: NWConnection, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let deadline = DispatchTime.now() + timeout
            let queue = DispatchQueue.global(qos: .utility)

            func poll() {
                switch connection.state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                case .cancelled:
                    continuation.resume(throwing: WebSocketError.closed)
                default:
                    if DispatchTime.now() >= deadline {
                        continuation.resume(throwing: WebSocketError.closed)
                    } else {
                        queue.asyncAfter(deadline: .now() + 0.05) {
                            poll()
                        }
                    }
                }
            }

            queue.async {
                poll()
            }
        }
    }

    private static func sendHTTP(connection: NWConnection, request: String) async throws {
        try await send(connection: connection, data: Data(request.utf8))
    }

    private static func send(connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
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
        while !bytes.containsCRLFCRLF {
            let chunk = try await reader.read(maxLength: 512, timeout: timeout)
            guard !chunk.isEmpty else { throw WebSocketError.emptyResponse }
            bytes.append(chunk)
            if bytes.count > 16_384 {
                break
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func parseStatusCode(_ response: String) -> Int {
        guard let line = response.split(separator: "\r\n").first else { return 0 }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return 0 }
        return Int(parts[1]) ?? 0
    }

    private static func buildFrame(opcode: UInt8, data: Data, mask: Bool) -> Data {
        let length = data.count
        var frame = Data()
        frame.append(0x80 | opcode)
        if mask {
            if length < 126 {
                frame.append(0x80 | UInt8(length))
            } else if length < 65_536 {
                frame.append(0x80 | 126)
                frame.append(contentsOf: withUnsafeBytes(of: UInt16(length).bigEndian) { Array($0) })
            } else {
                frame.append(0x80 | 127)
                frame.append(contentsOf: withUnsafeBytes(of: UInt64(length).bigEndian) { Array($0) })
            }
            let maskKey = Data((0..<4).map { _ in UInt8.random(in: .min ... .max) })
            frame.append(maskKey)
            frame.append(xor(data, maskKey))
        } else {
            if length < 126 {
                frame.append(UInt8(length))
            } else if length < 65_536 {
                frame.append(126)
                frame.append(contentsOf: withUnsafeBytes(of: UInt16(length).bigEndian) { Array($0) })
            } else {
                frame.append(127)
                frame.append(contentsOf: withUnsafeBytes(of: UInt64(length).bigEndian) { Array($0) })
            }
            frame.append(data)
        }
        return frame
    }

    private static func xor(_ data: Data, _ maskKey: Data) -> Data {
        let bytes = Array(maskKey)
        return Data(data.enumerated().map { index, byte in
            byte ^ bytes[index % bytes.count]
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

    init(connection: NWConnection) {
        self.connection = connection
    }

    func read(maxLength: Int, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: maxLength
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if isComplete {
                    continuation.resume(returning: Data())
                    return
                }
                continuation.resume(returning: data ?? Data())
            }
        }
    }
}
