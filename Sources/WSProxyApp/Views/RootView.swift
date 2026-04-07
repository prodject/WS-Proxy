import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openURL) private var openURL
    @State private var proxyLinkAlert = false
    @State private var presentedUpdate: AppUpdateInfo?

    var body: some View {
        TabView {
            NavigationStack {
                Form {
                    Section("Status") {
                        HStack {
                            Text("Engine")
                            Spacer()
                            Text(statusText)
                                .foregroundStyle(.secondary)
                        }
                        if let message = appState.lastMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Text(updateStatusText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Section("Connection") {
                        TextField("Host", text: $appState.settings.host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Port", value: $appState.settings.port, format: .number)
                            .keyboardType(.numberPad)
                        TextField("Secret", text: $appState.settings.secret)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Regenerate secret") {
                            appState.settings.regenerateSecret()
                            appState.save()
                        }
                    }

                    Section("DC mappings") {
                        ForEach(Array(appState.settings.dcIP.enumerated()), id: \.offset) { index, _ in
                            HStack {
                                TextField("DC mapping", text: Binding(
                                    get: { appState.settings.dcIP[index] },
                                    set: { appState.settings.dcIP[index] = $0 }
                                ))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                                Button(role: .destructive) {
                                    appState.settings.dcIP.remove(at: index)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Button("Add mapping") {
                            appState.settings.dcIP.append("1:149.154.175.50")
                        }
                    }

                    Section("Proxy behavior") {
                        Toggle("Verbose logging", isOn: $appState.settings.verbose)
                        Stepper("Buffer KB: \(appState.settings.bufferKB)", value: $appState.settings.bufferKB, in: 4...4096, step: 4)
                        Stepper("Pool size: \(appState.settings.poolSize)", value: $appState.settings.poolSize, in: 0...32)
                        Toggle("Cloudflare fallback", isOn: $appState.settings.cfProxyEnabled)
                        Toggle("CF priority", isOn: $appState.settings.cfProxyPriority)
                        TextField("CF proxy domain", text: $appState.settings.cfProxyDomain)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Stepper("Log max MB: \(appState.settings.logMaxMB, specifier: "%.1f")", value: $appState.settings.logMaxMB, in: 1...100, step: 1)
                        Toggle("Check updates", isOn: $appState.settings.checkUpdates)
                    }

                    Section("Actions") {
                        Button("Save settings") {
                            appState.save()
                        }
                        Button("Reset defaults", role: .destructive) {
                            appState.resetToDefaults()
                        }
                        Button("Start proxy") {
                            Task { await appState.startProxy() }
                        }
                        Button("Stop proxy") {
                            Task { await appState.stopProxy() }
                        }
                        Button("Check updates") {
                            Task { await appState.refreshUpdates(force: true) }
                        }
                        Button("Copy tg://proxy link") {
                            if let url = appState.generatedProxyURL {
                                UIPasteboard.general.string = url.absoluteString
                                appState.setMessage("Proxy link copied to clipboard")
                            }
                            proxyLinkAlert = true
                        }
                    }
                }
                .navigationTitle("WS Proxy")
                .alert("Proxy link", isPresented: $proxyLinkAlert) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text(appState.generatedProxyURL?.absoluteString ?? "Unavailable")
                }
                .alert(item: $presentedUpdate) { update in
                    Alert(
                        title: Text("Update available"),
                        message: Text("Installed: \(update.currentVersion)\nLatest: \(update.latestVersion)"),
                        primaryButton: .default(Text("Download IPA")) {
                            openURL(update.downloadURL ?? update.releasePageURL)
                        },
                        secondaryButton: .cancel()
                    )
                }
                .task {
                    await appState.checkForUpdatesIfNeeded()
                    if let update = appState.availableUpdate {
                        presentedUpdate = update
                    }
                }
                .onChange(of: appState.availableUpdate?.id) { _, _ in
                    presentedUpdate = appState.availableUpdate
                }
            }
            .tabItem {
                Label("Settings", systemImage: "slider.horizontal.3")
            }

            NavigationStack {
                LogsView()
            }
            .tabItem {
                Label("Logs", systemImage: "text.bubble")
            }
        }
    }

    private var statusText: String {
        switch appState.engineStatus {
        case .stopped:
            return "Stopped"
        case .running:
            return "Running"
        case .failed(let error):
            return "Failed: \(error)"
        }
    }

    private var updateStatusText: String {
        switch appState.updateStatus {
        case .idle:
            return "Updates: idle"
        case .checking:
            return "Updates: checking"
        case .upToDate(let version):
            return "Updates: up to date (\(version))"
        case .updateAvailable(let info):
            return "Updates: \(info.latestVersion) available"
        case .failed(let error):
            return "Updates: \(error)"
        }
    }
}
