import Foundation
import Network

final class ProxyConnectionSession {
    let id = UUID()
    private let connection: NWConnection
    private let logger: ProxyLogStore
    private let onClose: (UUID) -> Void
    private var isActive = false
    private var receiveBuffer = Data()
    private var parsedHandshake: MTProtoHandshake?

    init(
        connection: NWConnection,
        logger: ProxyLogStore,
        onClose: @escaping (UUID) -> Void
    ) {
        self.connection = connection
        self.logger = logger
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
        logger.append(
            .info,
            "Handshake parsed: DC\(handshake.dcID)\(handshake.isMedia ? "m" : "") \(handshake.transport.label)"
        )
    }

    private func finish() {
        guard isActive else { return }
        isActive = false
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
