import Foundation

enum TelegramRelayConnection {
    case webSocket(RawWebSocket)
    case tcp(RawTCPRelay)
}

final class TelegramWebSocketConnector {
    private let pool = TelegramWebSocketPool()
    private let directWebSocketTimeout: TimeInterval = 2.5
    private let fallbackRelayTimeout: TimeInterval = 4.0

    func connect(
        for handshake: MTProtoHandshake,
        settings: ProxySettings,
        logger: ProxyLogStore
    ) async throws -> TelegramRelayConnection {
        let domains = wsDomains(for: handshake.dcID, isMedia: handshake.isMedia)
        let targetIPs = targetIPs(for: handshake.dcID, settings: settings)
        let mediaTag = handshake.isMedia ? "m" : ""

        for targetIP in targetIPs {
            let poolKey = "dc\(handshake.dcID)\(handshake.isMedia ? "m" : "")@\(targetIP)"
            if let pooled = await pool.checkout(
                key: poolKey,
                targetIP: targetIP,
                domains: domains,
                desiredSize: settings.poolSize,
                logger: logger
            ) {
                logger.append(.info, "Using pooled WS for DC\(handshake.dcID)\(mediaTag) via \(targetIP)")
                return .webSocket(pooled)
            }

            for domain in domains {
                do {
                    logger.append(.info, "Connecting WS \(domain) -> \(targetIP)")
                    let ws = try await RawWebSocket.connect(
                        ip: targetIP,
                        domain: domain,
                        timeout: directWebSocketTimeout
                    )
                    return .webSocket(ws)
                } catch RawWebSocket.WebSocketError.invalidHandshake(let response) {
                    if Self.isRedirect(response) {
                        logger.append(.warning, "WS redirect for \(domain): \(Self.firstStatusLine(response))")
                        continue
                    }
                    logger.append(.warning, "WS handshake failed for \(domain): \(Self.firstStatusLine(response))")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    logger.append(.warning, "WS connect failed for \(domain): \(error.localizedDescription)")
                }
            }
        }

        for fallback in fallbackOrder(for: settings) {
            switch fallback {
            case .cfProxy:
                guard settings.cfProxyEnabled else { continue }
                let cfDomain = "kws\(handshake.dcID).\(settings.cfProxyDomain)"
                do {
                    logger.append(.info, "Connecting CF proxy \(cfDomain)")
                    let ws = try await RawWebSocket.connect(
                        ip: cfDomain,
                        domain: cfDomain,
                        timeout: fallbackRelayTimeout
                    )
                    return .webSocket(ws)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    logger.append(.warning, "CF proxy failed for DC\(handshake.dcID)\(mediaTag): \(error.localizedDescription)")
                }
            case .tcp:
                guard let fallbackIP = Self.defaultTargetIPs[handshake.dcID] else { continue }
                do {
                    logger.append(.info, "Connecting TCP fallback \(fallbackIP):443")
                    let tcp = try await RawTCPRelay.connect(
                        ip: fallbackIP,
                        timeout: fallbackRelayTimeout
                    )
                    return .tcp(tcp)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    logger.append(.warning, "TCP fallback failed for DC\(handshake.dcID)\(mediaTag): \(error.localizedDescription)")
                }
            }
        }

        throw RawWebSocket.WebSocketError.invalidHandshake("All Telegram relay endpoints failed for DC\(handshake.dcID)")
    }

    private enum FallbackKind {
        case cfProxy
        case tcp
    }

    private func fallbackOrder(for settings: ProxySettings) -> [FallbackKind] {
        if settings.cfProxyEnabled {
            return settings.cfProxyPriority ? [.cfProxy, .tcp] : [.tcp, .cfProxy]
        }
        return [.tcp]
    }

    func warmup(settings: ProxySettings, logger: ProxyLogStore) {
        guard settings.poolSize > 0 else { return }
        for dcID in Set(targetDCIDs(from: settings)) {
            let targetIPs = targetIPs(for: dcID, settings: settings)
            for targetIP in targetIPs {
                for isMedia in [false, true] {
                    let domains = wsDomains(for: dcID, isMedia: isMedia)
                    let poolKey = "dc\(dcID)\(isMedia ? "m" : "")@\(targetIP)"
                    Task {
                        await pool.warm(
                            key: poolKey,
                            targetIP: targetIP,
                            domains: domains,
                            desiredSize: settings.poolSize,
                            logger: logger
                        )
                    }
                }
            }
        }
    }

    func shutdown() async {
        await pool.shutdown()
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

    private func targetDCIDs(from settings: ProxySettings) -> [Int] {
        var ids = settings.dcIP.compactMap { entry in
            try? DCMapping.parse(entry).dc
        }
        ids.append(contentsOf: settings.dcIP.isEmpty ? [2, 4] : [])
        return ids
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
