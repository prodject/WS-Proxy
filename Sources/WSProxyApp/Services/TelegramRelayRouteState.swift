import Foundation

actor TelegramRelayRouteState {
    private var directWSFailUntil: [String: Date] = [:]
    private var directWSBlacklist: Set<String> = []

    func isDirectWSBlacklisted(for key: String) -> Bool {
        directWSBlacklist.contains(key)
    }

    func directWSTimeout(
        for key: String,
        normalTimeout: TimeInterval,
        degradedTimeout: TimeInterval
    ) -> TimeInterval {
        guard let until = directWSFailUntil[key] else { return normalTimeout }
        if until <= Date() {
            directWSFailUntil[key] = nil
            return normalTimeout
        }
        return degradedTimeout
    }

    func markDirectWSFailure(for key: String, duration: TimeInterval) {
        directWSFailUntil[key] = Date().addingTimeInterval(duration)
    }

    func clearDirectWSFailure(for key: String) {
        directWSFailUntil[key] = nil
    }

    func blacklistDirectWS(for key: String) {
        directWSBlacklist.insert(key)
    }
}
