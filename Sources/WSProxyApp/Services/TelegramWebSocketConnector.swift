import Foundation

final class TelegramWebSocketConnector {
    func connect(
        for handshake: MTProtoHandshake,
        settings: ProxySettings,
        logger: ProxyLogStore
    ) async throws -> RawWebSocket {
        let domains = wsDomains(for: handshake.dcID, isMedia: handshake.isMedia)
        let targetIPs = targetIPs(for: handshake.dcID, settings: settings)

        for targetIP in targetIPs {
            for domain in domains {
                do {
                    logger.append(.info, "Connecting WS \(domain) -> \(targetIP)")
                    return try await RawWebSocket.connect(ip: targetIP, domain: domain)
                } catch RawWebSocket.WebSocketError.invalidHandshake(let response) {
                    if Self.isRedirect(response) {
                        logger.append(.warning, "WS redirect for \(domain): \(Self.firstStatusLine(response))")
                        continue
                    }
                    logger.append(.warning, "WS handshake failed for \(domain): \(Self.firstStatusLine(response))")
                } catch is CancellationError {
                    logger.append(.warning, "WS connect cancelled for \(domain)")
                } catch {
                    logger.append(.warning, "WS connect failed for \(domain): \(error.localizedDescription)")
                }
            }
        }

        throw RawWebSocket.WebSocketError.invalidHandshake("All Telegram WS endpoints failed for DC\(handshake.dcID)")
    }

    private func targetIPs(for dcID: Int, settings: ProxySettings) -> [String] {
        var candidates: [String] = []
        for entry in settings.dcIP {
            if let mapping = try? DCMapping.parse(entry), mapping.dc == dcID {
                candidates.append(mapping.ip)
                break
            }
        }

        if let fallback = Self.defaultTargetIPs[dcID], !candidates.contains(fallback) {
            candidates.append(fallback)
        }

        if candidates.isEmpty {
            candidates.append("149.154.167.220")
        }

        return candidates
    }

    private func wsDomains(for dcID: Int, isMedia: Bool) -> [String] {
        if isMedia {
            return ["kws\(dcID)-1.web.telegram.org", "kws\(dcID).web.telegram.org"]
        }
        return ["kws\(dcID).web.telegram.org", "kws\(dcID)-1.web.telegram.org"]
    }

    private static let defaultTargetIPs: [Int: String] = [
        1: "149.154.175.50",
        2: "149.154.167.51",
        3: "149.154.175.100",
        4: "149.154.167.91",
        5: "149.154.171.5",
        203: "149.154.175.50"
    ]

    private static func isRedirect(_ response: String) -> Bool {
        [301, 302, 303, 307, 308].contains(firstStatusCode(response))
    }

    private static func firstStatusCode(_ response: String) -> Int {
        let line = firstStatusLine(response)
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return 0 }
        return Int(parts[1]) ?? 0
    }

    private static func firstStatusLine(_ response: String) -> String {
        response.components(separatedBy: "\r\n").first ?? response
    }
}
