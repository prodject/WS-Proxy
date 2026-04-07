import Foundation

final class TelegramRelayPermit {
    private let onRelease: @Sendable () async -> Void
    private var isReleased = false

    init(onRelease: @escaping @Sendable () async -> Void) {
        self.onRelease = onRelease
    }

    func release() async {
        guard !isReleased else { return }
        isReleased = true
        await onRelease()
    }
}

actor TelegramRelayConcurrencyLimiter {
    private let defaultLimit: Int
    private var activeCounts: [String: Int] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(defaultLimit: Int) {
        self.defaultLimit = max(1, defaultLimit)
    }

    func acquire(routeKey: String, limit: Int? = nil) async -> TelegramRelayPermit {
        let effectiveLimit = max(1, limit ?? defaultLimit)
        while (activeCounts[routeKey] ?? 0) >= effectiveLimit {
            await withCheckedContinuation { continuation in
                waiters[routeKey, default: []].append(continuation)
            }
        }

        activeCounts[routeKey, default: 0] += 1
        return TelegramRelayPermit { [weak self] in
            await self?.release(routeKey: routeKey)
        }
    }

    private func release(routeKey: String) {
        let current = activeCounts[routeKey] ?? 0
        if current <= 1 {
            activeCounts[routeKey] = nil
        } else {
            activeCounts[routeKey] = current - 1
        }

        if var queue = waiters[routeKey], !queue.isEmpty {
            let continuation = queue.removeFirst()
            waiters[routeKey] = queue.isEmpty ? nil : queue
            continuation.resume()
        }
    }
}
