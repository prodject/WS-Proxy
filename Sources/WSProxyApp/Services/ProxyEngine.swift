import Foundation

enum ProxyEngineStatus: Equatable {
    case stopped
    case running
    case failed(String)
}

protocol ProxyEngine {
    func start(with settings: ProxySettings) async throws
    func stop() async throws
}

final class LocalProxyEngine: ProxyEngine {
    private var isRunning = false

    func start(with settings: ProxySettings) async throws {
        try settings.validate()
        isRunning = true
    }

    func stop() async throws {
        isRunning = false
    }
}
