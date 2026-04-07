import Foundation

enum ProxyLinkBuilder {
    static func makeURL(from settings: ProxySettings) -> URL? {
        let host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = "dd" + settings.secret.lowercased()
        var components = URLComponents()
        components.scheme = "tg"
        components.host = "proxy"
        components.queryItems = [
            .init(name: "server", value: host),
            .init(name: "port", value: String(settings.port)),
            .init(name: "secret", value: secret)
        ]
        return components.url
    }
}
