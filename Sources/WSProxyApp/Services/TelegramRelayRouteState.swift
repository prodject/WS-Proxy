import Foundation

actor TelegramRelayRouteState {
    private var directWSCooldownUntil: [String: Date] = [:]

    func isDirectWSAllowed(for key: String) -> Bool {
        guard let until = directWSCooldownUntil[key] else { return true }
        if until <= Date() {
            directWSCooldownUntil[key] = nil
            return true
        }
        return false
    }

    func setDirectWSCooldown(for key: String, duration: TimeInterval) {
        directWSCooldownUntil[key] = Date().addingTimeInterval(duration)
    }

    func clearDirectWSCooldown(for key: String) {
        directWSCooldownUntil[key] = nil
    }
}
