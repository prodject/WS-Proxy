import Foundation

final class ProxyLogStore: ObservableObject {
    @Published private(set) var entries: [ProxyLogEntry] = []

    private let maxEntries: Int

    init(maxEntries: Int = 500) {
        self.maxEntries = max(50, maxEntries)
    }

    func append(_ level: ProxyLogLevel, _ message: String) {
        let update = {
            self.entries.append(ProxyLogEntry(level: level, message: message))
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    func clear() {
        let update = {
            self.entries.removeAll(keepingCapacity: true)
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    func seedWithPlaceholder() {
        guard entries.isEmpty else { return }
        append(.info, "Proxy app launched")
        append(.info, "Waiting for user to start the proxy engine")
    }
}
