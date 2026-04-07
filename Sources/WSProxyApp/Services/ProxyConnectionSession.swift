import Foundation
import Network

final class ProxyConnectionSession {
    let id = UUID()
    private let connection: NWConnection
    private let logger: ProxyLogStore
    private let settings: ProxySettings
    private let connector: TelegramWebSocketConnector
    private let onClose: (UUID) -> Void
    private var isActive = false
    private var receiveBuffer = Data()
    private var parsedHandshake: MTProtoHandshake?
    private var packetSplitter: MTProtoPacketSplitter?
    private var webSocket: RawWebSocket?
    private var bridgeTask: Task<Void, Never>?

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
        Task { [webSocket] in
            await webSocket?.close()
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
                self.finish()
                return
            }
            self.receiveNext()
        }
    }

    private func handleIncoming(_ data: Data) {
        receiveBuffer.append(data)
        logger.append(.debug, "Received \(data.count) bytes")

        guard parsedHandshake == nil else { return }
        guard receiveBuffer.count >= MTProtoHandshakeParser.handshakeLength else { return }

        let handshakeData = receiveBuffer.prefix(MTProtoHandshakeParser.handshakeLength)
        guard let handshake = MTProtoHandshakeParser.parse(Data(handshakeData)) else {
            logger.append(.warning, "Received non-MTProto handshake payload")
            return
        }

        parsedHandshake = handshake
        packetSplitter = MTProtoPacketSplitter(transport: handshake.transport)
        logger.append(
            .info,
            "Handshake parsed: DC\(handshake.dcID)\(handshake.isMedia ? "m" : "") \(handshake.transport.label)"
        )
        startWebSocketBridge(handshake)
    }

    private func startWebSocketBridge(_ handshake: MTProtoHandshake) {
        guard bridgeTask == nil else { return }
        bridgeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let ws = try await connector.connect(
                    for: handshake,
                    settings: settings,
                    logger: logger
                )
                self.webSocket = ws
                self.logger.append(.info, "WebSocket bridge ready for DC\(handshake.dcID)")
                if !self.receiveBuffer.isEmpty {
                    let buffered = self.receiveBuffer
                    self.receiveBuffer.removeAll(keepingCapacity: true)
                    let packets = self.packetSplitter?.split(buffered) ?? [buffered]
                    for packet in packets {
                        try await ws.send(packet)
                        self.logger.append(.debug, "Forwarded \(packet.count) bytes to WS")
                    }
                }
                await self.pumpClientToWebSocket(ws)
            } catch {
                self.logger.append(.error, "WebSocket bridge failed: \(error.localizedDescription)")
                self.finish()
            }
        }
    }

    private func pumpClientToWebSocket(_ ws: RawWebSocket) async {
        while isActive {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !receiveBuffer.isEmpty {
                let chunk = receiveBuffer
                receiveBuffer.removeAll(keepingCapacity: true)
                do {
                    let packets = packetSplitter?.split(chunk) ?? [chunk]
                    for packet in packets {
                        try await ws.send(packet)
                        logger.append(.debug, "Forwarded \(packet.count) bytes to WS")
                    }
                } catch {
                    logger.append(.error, "WS send failed: \(error.localizedDescription)")
                    finish()
                    return
                }
            }
        }
    }

    private func finish() {
        guard isActive else { return }
        isActive = false
        bridgeTask?.cancel()
        bridgeTask = nil
        Task { [webSocket] in
            await webSocket?.close()
        }
        onClose(id)
    }

    private func describe(endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        case .service(let name, let type, let domain, _):
            return "\(name ?? "?").\(type).\(domain)"
        case .unix(let path):
            return path
        case .url(let url):
            return url.absoluteString
        @unknown default:
            return "unknown"
        }
    }
}
