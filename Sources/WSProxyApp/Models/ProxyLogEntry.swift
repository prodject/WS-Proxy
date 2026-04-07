import Foundation

enum ProxyLogLevel: String, Codable, CaseIterable {
    case debug
    case info
    case warning
    case error
}

struct ProxyLogEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let level: ProxyLogLevel
    let message: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: ProxyLogLevel,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}
