import Foundation
import Network

final class ProxyConnectionSession: @unchecked Sendable {
    let id = UUID()
    private let connection: NWConnection
    private let logger: ProxyLogStore
    private let settings: ProxySettings
    private let connector: TelegramWebSocketConnector
    private let onClose: (UUID) -> Void
    private var isActive = false
    private let bufferLock = NSLock()
    private var receiveBuffer = Data()
    private var parsedHandshake: MTProtoHandshake?
    private var bridgeContext: MTProtoBridgeContext?
    private var webSocket: RawWebSocket?
    private var tcpRelay: RawTCPRelay?
    private var bridgeTask: Task<Void, Never>?
    private var relayPumpTask: Task<Void, Never>?

    init(
        connection: NWConnection,
        logger: ProxyLogStore,
        settings: ProxySettings,
        connector: TelegramWebSocketConnector,
        onClose: @escaping (UUID) -> Void
    ) {
        self.connection = connection
        self.logger = logger
        self.settings = settings
        self.connector = connector
        self.onClose = onClose
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        logger.append(.info, "Accepted connection from \(describe(endpoint: connection.endpoint))")
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveNext()
            case .failed(let error):
                self.logger.append(.error, "Connection failed: \(error.localizedDescription)")
                self.finish()
            case .cancelled:
                self.finish()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
    }

    func stop() {
        bridgeTask?.cancel()
        bridgeTask = nil
        relayPumpTask?.cancel()
        relayPumpTask = nil
        Task { [webSocket, tcpRelay] in
            await webSocket?.close()
            await tcpRelay?.close()
        }
        connection.cancel()
        finish()
    }

    private func receiveNext() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 4096
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.logger.append(.warning, "Connection receive error: \(error.localizedDescription)")
                self.finish()
                return
            }
            if let data, !data.isEmpty {
                self.handleIncoming(data)
            }
            if isComplete {
                self.logger.append(.info, "Client closed connection")
                if self.bridgeContext != nil, self.webSocket != nil {
                    Task { [weak self] in
                        guard let self, let ws = self.webSocket else { return }
                        do {
                            try await self.flushClientTail(to: ws)
                        } catch {
                            self.logger.append(.warning, "Failed to flush client tail: \(error.localizedDescription)")
                        }
                        self.finish()
                    }
                    return
                }
                if self.bridgeContext != nil, self.tcpRelay != nil {
                    self.finish()
                    return
                }
                self.finish()
                return
            }
            self.receiveNext()
        }
    }

    private func handleIncoming(_ data: Data) {
        appendToReceiveBuffer(data)
        logger.append(.debug, "Received \(data.count) bytes")

        guard parsedHandshake == nil else { return }
        guard receiveBufferCount() >= MTProtoHandshakeParser.handshakeLength else { return }

        let handshakeData = takeHandshakeBytes()
        guard let handshake = MTProtoHandshakeParser.parse(Data(handshakeData), secretHex: settings.secret) else {
            logger.append(.warning, "Received non-MTProto handshake payload")
            return
        }

        parsedHandshake = handshake
        logger.append(
            .info,
            "Handshake parsed: DC\(handshake.dcID)\(handshake.isMedia ? "m" : "") \(handshake.transport.label)"
        )
        do {
            bridgeContext = try MTProtoBridgeContext(
                handshake: handshake,
                secretHex: settings.secret
            )
            startRelayBridge(handshake)
        } catch {
            logger.append(.error, "Bridge context failed: \(error.localizedDescription)")
            finish()
        }
    }

    private func startRelayBridge(_ handshake: MTProtoHandshake) {
        guard bridgeTask == nil else { return }
        bridgeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let relay = try await connector.connect(
                    for: handshake,
                    settings: settings,
                    logger: logger
                )
                guard let bridgeContext else {
                    throw MTProtoCryptoError.cryptorCreationFailed
                }
                switch relay {
                case .webSocket(let ws):
                    self.webSocket = ws
                    self.logger.append(.info, "WebSocket bridge ready for DC\(handshake.dcID)")
                    try await ws.send(bridgeContext.relayInit)
                    self.startWebSocketReceivePump(ws)
                    try await self.flushPendingClientBytes(to: ws)
                case .tcp(let tcp):
                    self.tcpRelay = tcp
                    self.logger.append(.info, "TCP fallback bridge ready for DC\(handshake.dcID)")
                    try await tcp.send(bridgeContext.relayInit)
                    self.startTCPReceivePump(tcp)
                    try await self.flushPendingClientBytes(to: tcp)
                }
            } catch {
                self.logger.append(.error, "Relay bridge failed: \(error.localizedDescription)")
                self.finish()
            }
        }
    }

    private func startWebSocketReceivePump(_ ws: RawWebSocket) {
        guard relayPumpTask == nil else { return }
        relayPumpTask = Task { [weak self] in
            guard let self else { return }
            await self.pumpWebSocketToClient(ws)
        }
    }

    private func startTCPReceivePump(_ tcp: RawTCPRelay) {
        guard relayPumpTask == nil else { return }
        relayPumpTask = Task { [weak self] in
            guard let self else { return }
            await self.pumpTCPRelayToClient(tcp)
        }
    }

    private func pumpWebSocketToClient(_ ws: RawWebSocket) async {
        while isActive {
            do {
                guard let data = try await ws.recv() else { break }
                guard let bridgeContext else { continue }
                let plain = try bridgeContext.decodeRelayChunk(data)
                try await writeToClient(plain)
                logger.append(.debug, "Forwarded \(plain.count) bytes to client")
            } catch {
                logger.append(.error, "WS receive failed: \(error.localizedDescription)")
                finish()
                return
            }
        }
        finish()
    }

    private func pumpTCPRelayToClient(_ tcp: RawTCPRelay) async {
        while isActive {
            do {
                guard let data = try await tcp.recv() else { break }
                guard let bridgeContext else { continue }
                let plain = try bridgeContext.decodeRelayChunk(data)
                try await writeToClient(plain)
                logger.append(.debug, "Forwarded \(plain.count) bytes to client via TCP")
            } catch {
                logger.append(.error, "TCP receive failed: \(error.localizedDescription)")
                finish()
                return
            }
        }
        finish()
    }

    private func flushPendingClientBytes(to ws: RawWebSocket) async throws {
        while let chunk = takePendingClientChunk() {
            guard let bridgeContext else { break }
            let packets = try bridgeContext.encodeClientChunk(chunk)
            if packets.isEmpty {
                continue
            }
            if packets.count == 1 {
                try await ws.send(packets[0])
            } else {
                try await ws.sendBatch(packets)
            }
            logger.append(.debug, "Forwarded \(chunk.count) bytes to WS")
        }
    }

    private func flushPendingClientBytes(to tcp: RawTCPRelay) async throws {
        while let chunk = takePendingClientChunk() {
            guard let bridgeContext else { break }
            let encrypted = try bridgeContext.encodeClientStreamChunk(chunk)
            if encrypted.isEmpty {
                continue
            }
            try await tcp.send(encrypted)
            logger.append(.debug, "Forwarded \(chunk.count) bytes to TCP relay")
        }
    }

    private func flushClientTail(to ws: RawWebSocket) async throws {
        guard let bridgeContext else { return }
        let tailPackets = try bridgeContext.flushClientTail()
        if tailPackets.isEmpty {
            return
        }
        if tailPackets.count == 1 {
            try await ws.send(tailPackets[0])
        } else {
            try await ws.sendBatch(tailPackets)
        }
    }

    private func writeToClient(_ data: Data) async throws {
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

    private func appendToReceiveBuffer(_ data: Data) {
        bufferLock.withLock {
            receiveBuffer.append(data)
        }
    }

    private func receiveBufferCount() -> Int {
        bufferLock.withLock { receiveBuffer.count }
    }

    private func takeHandshakeBytes() -> Data {
        bufferLock.withLock {
            let handshake = receiveBuffer.prefix(MTProtoHandshakeParser.handshakeLength)
            receiveBuffer.removeFirst(min(receiveBuffer.count, MTProtoHandshakeParser.handshakeLength))
            return Data(handshake)
        }
    }

    private func takePendingClientChunk() -> Data? {
        bufferLock.withLock {
            guard !receiveBuffer.isEmpty else { return nil }
            let chunk = receiveBuffer
            receiveBuffer.removeAll(keepingCapacity: true)
            return chunk
        }
    }

    private func finish() {
        guard isActive else { return }
        isActive = false
        bridgeTask?.cancel()
        bridgeTask = nil
        relayPumpTask?.cancel()
        relayPumpTask = nil
        Task { [webSocket, tcpRelay] in
            await webSocket?.close()
            await tcpRelay?.close()
        }
        connection.cancel()
        onClose(id)
    }

    private func describe(endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        case .service(let name, let type, let domain, _):
            return "\(name).\(type).\(domain)"
        case .unix(let path):
            return path
        case .url(let url):
            return url.absoluteString
        case .opaque:
            return "opaque"
        @unknown default:
            return "unknown"
        }
    }
}
