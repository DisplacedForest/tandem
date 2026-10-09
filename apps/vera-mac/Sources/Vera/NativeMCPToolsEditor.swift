import SwiftUI

struct NativeMCPToolsEditor: View {
    @ObservedObject var manager: NativeMCPManager
    @EnvironmentObject var config: ConfigStore
    @EnvironmentObject var store: ChatStore
    @State private var temporaryTokens: [String: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connected services").font(.headline)
            if let error = manager.configurationError { Text(error).foregroundStyle(.orange) }
            if manager.servers.isEmpty {
                Text("No remote services configured. Add a reviewed server and approved read tools to your configuration, then connect here.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            ForEach(manager.servers) { server in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(server.configuration.name).fontWeight(.medium)
                        Spacer()
                        if server.connected || server.connecting {
                            Button(server.connecting ? "Cancel connection" : "Disconnect") {
                                temporaryTokens.removeValue(forKey: server.id)
                                Task { await manager.disconnect(server.id) }
                            }
                        } else {
                            Button("Connect") {
                                let token = temporaryTokens.removeValue(forKey: server.id)
                                Task { await manager.connect(server.id, token: token) }
                            }
                        }
                    }
                    Text(server.configuration.endpoint.absoluteString).font(.caption).textSelection(.enabled)
                    Text(server.status).font(.caption).foregroundStyle(Theme.textSecondary)
                    if server.configuration.authentication == .bearer && !server.connected && !server.connecting {
                        SecureField("Temporary access token", text: Binding(get: { temporaryTokens[server.id] ?? "" }, set: { temporaryTokens[server.id] = $0 }))
                            .textFieldStyle(.roundedBorder)
                        Text("Used only for this connection. Forgotten on disconnect or after one hour. Enter the token again after reopening Vera.")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(server.tools) { tool in
                        Toggle(isOn: Binding(get: { config.nativeSettings.enabledToolIDs.contains(tool.id) }, set: {
                            config.setNativeTool(tool.id, enabled: $0)
                            store.updateNativeToolConsent(config.nativeSettings.enabledToolIDs)
                        })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tool.remoteName)
                                if let reason = tool.reason { Text(reason).font(.caption).foregroundStyle(.orange) }
                            }
                        }.disabled(!tool.callable)
                        DisclosureGroup("Inspect service tool") {
                            Text("Service-provided description").font(.caption).foregroundStyle(Theme.textSecondary)
                            Text(tool.description).font(.caption).textSelection(.enabled)
                            Text("Argument schema").font(.caption).foregroundStyle(Theme.textSecondary)
                            Text(String(decoding: (try? tool.schema.piData()) ?? Data(), as: UTF8.self))
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }.padding(10).background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text("Only explicitly approved reads are available. A service cannot grant itself permission. Connections stop when Vera quits; reconnect here after reopening.")
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        }
        .onDisappear { temporaryTokens.removeAll() }
    }
}
