import Foundation

actor TelegramWebSocketPool {
    private struct PoolEntry {
        let createdAt: Date
        let socket: RawWebSocket
    }

    private let maxAge: TimeInterval = 120
    private var entries: [String: [PoolEntry]] = [:]
    private var refillTasks: [String: Task<Void, Never>] = [:]

    func checkout(
        key: String,
        targetIP: String,
        domains: [String],
        desiredSize: Int,
        logger: ProxyLogStore
    ) async -> RawWebSocket? {
        trimExpired(for: key)
        if var bucket = entries[key], !bucket.isEmpty {
            let entry = bucket.removeFirst()
            entries[key] = bucket
            if desiredSize > 0 {
                scheduleRefillIfNeeded(
                    key: key,
                    targetIP: targetIP,
                    domains: domains,
                    desiredSize: desiredSize,
                    logger: logger
                )
            }
            logger.append(.debug, "WS pool hit for \(key)")
            return entry.socket
        }

        if desiredSize > 0 {
            scheduleRefillIfNeeded(
                key: key,
                targetIP: targetIP,
                domains: domains,
                desiredSize: desiredSize,
                logger: logger
            )
        }
        return nil
    }

    func warm(
        key: String,
        targetIP: String,
        domains: [String],
        desiredSize: Int,
        logger: ProxyLogStore
    ) {
        guard desiredSize > 0 else { return }
        scheduleRefillIfNeeded(
            key: key,
            targetIP: targetIP,
            domains: domains,
            desiredSize: desiredSize,
            logger: logger
        )
    }

    func shutdown() async {
        for (_, task) in refillTasks {
            task.cancel()
        }
        refillTasks.removeAll()

        for (_, bucket) in entries {
            for entry in bucket {
                await entry.socket.close()
            }
        }
        entries.removeAll()
    }

    private func scheduleRefillIfNeeded(
        key: String,
        targetIP: String,
        domains: [String],
        desiredSize: Int,
        logger: ProxyLogStore
    ) {
        guard refillTasks[key] == nil else { return }

        refillTasks[key] = Task {
            defer { clearRefillTask(for: key) }
            await refill(
                key: key,
                targetIP: targetIP,
                domains: domains,
                desiredSize: desiredSize,
                logger: logger
            )
        }
    }

    private func refill(
        key: String,
        targetIP: String,
        domains: [String],
        desiredSize: Int,
        logger: ProxyLogStore
    ) async {
        trimExpired(for: key)
        let currentCount = entries[key]?.count ?? 0
        guard currentCount < desiredSize else { return }

        for _ in currentCount..<desiredSize {
            if Task.isCancelled { return }
            do {
                if let socket = try await connect(targetIP: targetIP, domains: domains) {
                    var bucket = entries[key] ?? []
                    bucket.append(PoolEntry(createdAt: Date(), socket: socket))
                    entries[key] = bucket
                } else {
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                logger.append(.debug, "WS pool refill failed for \(key): \(error.localizedDescription)")
                return
            }
        }
    }

    private func connect(targetIP: String, domains: [String]) async throws -> RawWebSocket? {
        for domain in domains {
            do {
                return try await RawWebSocket.connect(ip: targetIP, domain: domain, timeout: 8)
            } catch RawWebSocket.WebSocketError.invalidHandshake(let response) {
                if [301, 302, 303, 307, 308].contains(Self.firstStatusCode(response)) {
                    continue
                }
                return nil
            }
        }
        return nil
    }

    private func trimExpired(for key: String) {
        guard let bucket = entries[key] else { return }
        let now = Date()
        let fresh = bucket.filter { now.timeIntervalSince($0.createdAt) < maxAge }
        entries[key] = fresh
    }

    private func clearRefillTask(for key: String) {
        refillTasks[key] = nil
    }

    private static func firstStatusCode(_ response: String) -> Int {
        let line = response.components(separatedBy: "\r\n").first ?? response
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return 0 }
        return Int(parts[1]) ?? 0
    }
}
