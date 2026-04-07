import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var logStore: ProxyLogStore

    var body: some View {
        List {
            if logStore.entries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No logs yet")
                        .font(.headline)
                    Text("Start the proxy to see connection and lifecycle events.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .padding(.vertical, 12)
            } else {
                ForEach(logStore.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.level.rawValue.uppercased())
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(color(for: entry.level))
                            Spacer()
                            Text(entry.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.message)
                            .font(.body)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Logs")
        .toolbar {
            Button("Clear") {
                logStore.clear()
            }
        }
    }

    private func color(for level: ProxyLogLevel) -> Color {
        switch level {
        case .debug:
            return .secondary
        case .info:
            return .blue
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}
