import Foundation
import Network

enum ProxyEngineStatus: Equatable {
    case stopped
    case running
    case failed(String)
}

protocol ProxyEngine {
    func start(with settings: ProxySettings, logger: ProxyLogStore) async throws
    func stop(logger: ProxyLogStore) async throws
}

final class LocalProxyEngine: ProxyEngine, @unchecked Sendable {
    private let queue = DispatchQueue(label: "wsproxy.localproxy")
    private var listener: NWListener?
    private var sessions: [UUID: ProxyConnectionSession] = [:]
    private let connector = TelegramWebSocketConnector()

    func start(with settings: ProxySettings, logger: ProxyLogStore) async throws {
        try settings.validate()
        guard listener == nil else {
            logger.append(.warning, "Proxy engine already running")
            return
        }

        let portValue = NWEndpoint.Port(rawValue: UInt16(settings.port)) ?? 1443
        let parameters = NWParameters.tcp
        let listener = try NWListener(using: parameters, on: portValue)
        listener.newConnectionHandler = { [weak self, weak logger] connection in
            guard let self, let logger else {
                connection.cancel()
                return
            }
            let session = ProxyConnectionSession(
                connection: connection,
                logger: logger,
                settings: settings,
                connector: self.connector,
                onClose: { [weak self] id in
                    self?.queue.async {
                        self?.sessions[id] = nil
                    }
                }
            )
            self.queue.async {
                self.sessions[session.id] = session
            }
            session.start()
        }
        listener.stateUpdateHandler = { [weak logger] state in
            switch state {
            case .ready:
                logger?.append(.info, "Local listener ready on port \(settings.port)")
            case .failed(let error):
                logger?.append(.error, "Listener failed: \(error.localizedDescription)")
            case .cancelled:
                logger?.append(.info, "Local listener cancelled")
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
        connector.warmup(settings: settings, logger: logger)
        logger.append(.info, "Proxy engine started on \(settings.host):\(settings.port)")
        logger.append(.debug, "Buffer: \(settings.bufferKB) KB, pool: \(settings.poolSize)")
        logger.append(.debug, "CF fallback: \(settings.cfProxyEnabled ? "enabled" : "disabled")")
    }

    func stop(logger: ProxyLogStore) async throws {
        listener?.cancel()
        listener = nil
        await connector.shutdown()
        queue.sync {
            sessions.values.forEach { $0.stop() }
            sessions.removeAll()
        }
        logger.append(.info, "Proxy engine stopped")
    }
}
