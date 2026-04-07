import Foundation

struct ProxySettings: Codable, Equatable {
    var host: String
    var port: Int
    var secret: String
    var dcIP: [String]
    var verbose: Bool
    var bufferKB: Int
    var poolSize: Int
    var cfProxyEnabled: Bool
    var cfProxyPriority: Bool
    var cfProxyDomain: String
    var logMaxMB: Double
    var checkUpdates: Bool

    static let `default` = ProxySettings(
        host: "127.0.0.1",
        port: 1443,
        secret: Self.makeSecret(),
        dcIP: [
            "2:149.154.167.220",
            "4:149.154.167.220"
        ],
        verbose: false,
        bufferKB: 256,
        poolSize: 4,
        cfProxyEnabled: true,
        cfProxyPriority: true,
        cfProxyDomain: "pclead.co.uk",
        logMaxMB: 5.0,
        checkUpdates: true
    )

    static func makeSecret() -> String {
        let bytes = (0..<16).map { _ in UInt8.random(in: UInt8.min ... UInt8.max) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    mutating func regenerateSecret() {
        secret = Self.makeSecret()
    }

    func validate() throws {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.field("Host can't be empty")
        }
        guard (1...65535).contains(port) else {
            throw ValidationError.field("Port must be between 1 and 65535")
        }
        guard secret.count == 32, secret.allSatisfy({ $0.isHexDigit }) else {
            throw ValidationError.field("Secret must be 32 hex characters")
        }
        guard bufferKB >= 4 else {
            throw ValidationError.field("Buffer must be at least 4 KB")
        }
        guard poolSize >= 0 else {
            throw ValidationError.field("Pool size can't be negative")
        }
        guard logMaxMB >= 1 else {
            throw ValidationError.field("Log size must be at least 1 MB")
        }
        try dcIP.forEach { line in
            _ = try DCMapping.parse(line)
        }
    }
}

enum ValidationError: LocalizedError, Equatable {
    case field(String)

    var errorDescription: String? {
        switch self {
        case .field(let message):
            return message
        }
    }
}

struct DCMapping: Equatable {
    let dc: Int
    let ip: String

    static func parse(_ value: String) throws -> DCMapping {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let dc = Int(parts[0]), isIPv4(parts[1]) else {
            throw ValidationError.field("Invalid DC mapping: \(value)")
        }
        return DCMapping(dc: dc, ip: parts[1])
    }

    private static func isIPv4(_ value: String) -> Bool {
        let octets = value.split(separator: ".")
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { part in
            guard let number = Int(part), (0...255).contains(number) else {
                return false
            }
            return true
        }
    }
}
