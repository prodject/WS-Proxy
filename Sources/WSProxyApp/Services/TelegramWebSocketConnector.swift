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
        let mediaTag = handshake.isMedia ? "m" : ""
        let domains = wsDomains(for: handshake.dcID, isMedia: handshake.isMedia)
        let targetIP = directTargetIP(for: handshake.dcID, settings: settings)

        if let targetIP {
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
        }

        return try await raceRelayCandidates(
            handshake: handshake,
            settings: settings,
            logger: logger
        )
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
            guard let targetIP = directTargetIP(for: dcID, settings: settings) else { continue }
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

    func shutdown() async {
        await pool.shutdown()
    }

    private func directTargetIP(for dcID: Int, settings: ProxySettings) -> String? {
        for entry in settings.dcIP {
            if let mapping = try? DCMapping.parse(entry), mapping.dc == dcID {
                return mapping.ip
            }
        }
        return Self.defaultTargetIPs[dcID]
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

    private func raceRelayCandidates(
        handshake: MTProtoHandshake,
        settings: ProxySettings,
        logger: ProxyLogStore
    ) async throws -> TelegramRelayConnection {
        let mediaTag = handshake.isMedia ? "m" : ""
        let domains = wsDomains(for: handshake.dcID, isMedia: handshake.isMedia)
        let targetIP = directTargetIP(for: handshake.dcID, settings: settings)
        let fallbackIP = Self.defaultTargetIPs[handshake.dcID]

        return try await withThrowingTaskGroup(of: TelegramRelayConnection?.self) { group in
            if let targetIP {
                group.addTask { [directWebSocketTimeout] in
                    try await self.connectDirectWebSocket(
                        targetIP: targetIP,
                        domains: domains,
                        timeout: directWebSocketTimeout,
                        logger: logger
                    ).map { .webSocket($0) }
                }
            }

            if settings.cfProxyEnabled {
                let cfDomain = "kws\(handshake.dcID).\(settings.cfProxyDomain)"
                group.addTask { [fallbackRelayTimeout] in
                    logger.append(.info, "Connecting CF proxy \(cfDomain)")
                    do {
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
                        return nil
                    }
                }
            }

            if let fallbackIP {
                group.addTask { [fallbackRelayTimeout] in
                    logger.append(.info, "Connecting TCP fallback \(fallbackIP):443")
                    do {
                        let tcp = try await RawTCPRelay.connect(
                            ip: fallbackIP,
                            timeout: fallbackRelayTimeout
                        )
                        return .tcp(tcp)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        logger.append(.warning, "TCP fallback failed for DC\(handshake.dcID)\(mediaTag): \(error.localizedDescription)")
                        return nil
                    }
                }
            }

            var sawCandidate = false
            while let candidate = try await group.next() {
                sawCandidate = true
                if let candidate {
                    group.cancelAll()
                    return candidate
                }
            }

            if !sawCandidate {
                throw RawWebSocket.WebSocketError.invalidHandshake("No relay candidates configured for DC\(handshake.dcID)")
            }
            throw RawWebSocket.WebSocketError.invalidHandshake("All Telegram relay endpoints failed for DC\(handshake.dcID)")
        }
    }

    private func connectDirectWebSocket(
        targetIP: String,
        domains: [String],
        timeout: TimeInterval,
        logger: ProxyLogStore
    ) async throws -> RawWebSocket? {
        try await withThrowingTaskGroup(of: (String, Result<RawWebSocket, Error>).self) { group in
            for domain in domains {
                group.addTask {
                    do {
                        let ws = try await RawWebSocket.connect(
                            ip: targetIP,
                            domain: domain,
                            timeout: timeout
                        )
                        return (domain, .success(ws))
                    } catch {
                        return (domain, .failure(error))
                    }
                }
                logger.append(.info, "Connecting WS \(domain) -> \(targetIP)")
            }

            var firstError: Error?
            while let (domain, result) = try await group.next() {
                switch result {
                case .success(let ws):
                    group.cancelAll()
                    return ws
                case .failure(let error as CancellationError):
                    group.cancelAll()
                    throw error
                case .failure(let error as RawWebSocket.WebSocketError):
                    if case .invalidHandshake(let response) = error, Self.isRedirect(response) {
                        logger.append(.warning, "WS redirect for \(domain): \(Self.firstStatusLine(response))")
                    } else {
                        logger.append(.warning, "WS connect failed for \(domain): \(error.localizedDescription)")
                    }
                    if firstError == nil {
                        firstError = error
                    }
                case .failure(let error):
                    logger.append(.warning, "WS connect failed for \(domain): \(error.localizedDescription)")
                    if firstError == nil {
                        firstError = error
                    }
                }
            }

            if let firstError {
                throw firstError
            }
            return nil
        }
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
