import Foundation
import Network

final class RawTCPRelay: @unchecked Sendable {
    enum TCPRelayError: LocalizedError {
        case closed

        var errorDescription: String? {
            switch self {
            case .closed:
                return "TCP relay closed"
            }
        }
    }

    private let reader: AsyncByteStreamReader
    private let writer: NWConnection
    private var isClosed = false

    private init(reader: AsyncByteStreamReader, writer: NWConnection) {
        self.reader = reader
        self.writer = writer
    }

    static func connect(ip: String, port: UInt16 = 443, timeout: TimeInterval = 10) async throws -> RawTCPRelay {
        try await RawWebSocket.withTimeout(seconds: timeout) {
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                throw TCPRelayError.closed
            }
            let connection = NWConnection(
                host: NWEndpoint.Host(ip),
                port: endpointPort,
                using: .tcp
            )
            connection.start(queue: .global(qos: .utility))
            do {
                try await RawWebSocket.waitUntilReady(connection, timeout: timeout)
                return RawTCPRelay(
                    reader: AsyncByteStreamReader(connection: connection),
                    writer: connection
                )
            } catch {
                connection.cancel()
                throw error
            }
        }
    }

    func send(_ data: Data) async throws {
        guard !isClosed else { throw TCPRelayError.closed }
        try await RawWebSocket.sendData(connection: writer, data: data)
    }

    func recv() async throws -> Data? {
        guard !isClosed else { return nil }
        let chunk = try await reader.readChunk(maxLength: 65_536)
        if chunk.isEmpty {
            isClosed = true
            writer.cancel()
            return nil
        }
        return chunk
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        writer.cancel()
    }
}
