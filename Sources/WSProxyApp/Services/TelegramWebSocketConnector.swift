import Foundation

final class TelegramWebSocketConnector {
    func connect(
        for handshake: MTProtoHandshake,
        settings: ProxySettings,
        logger: ProxyLogStore
    ) async throws -> RawWebSocket {
        let domains = wsDomains(for: handshake.dcID, isMedia: handshake.isMedia)
        let targetIP = targetIP(for: handshake.dcID, settings: settings)

        for domain in domains {
            do {
                logger.append(.info, "Connecting WS \(domain) -> \(targetIP)")
                return try await RawWebSocket.connect(ip: targetIP, domain: domain)
            } catch {
                logger.append(.warning, "WS connect failed for \(domain): \(error.localizedDescription)")
            }
        }

        throw RawWebSocket.WebSocketError.invalidHandshake("Unable to connect to Telegram WS")
    }

    private func targetIP(for dcID: Int, settings: ProxySettings) -> String {
        for entry in settings.dcIP {
            if let mapping = try? DCMapping.parse(entry), mapping.dc == dcID {
                return mapping.ip
            }
        }
        return "149.154.167.220"
    }

    private func wsDomains(for dcID: Int, isMedia: Bool) -> [String] {
        if isMedia {
            return ["kws\(dcID)-1.web.telegram.org", "kws\(dcID).web.telegram.org"]
        }
        return ["kws\(dcID).web.telegram.org", "kws\(dcID)-1.web.telegram.org"]
    }
}
