import SwiftUI

struct NativeMCPToolsEditor: View {
    @ObservedObject var manager: NativeMCPManager
    @EnvironmentObject var config: ConfigStore
    @EnvironmentObject var store: ChatStore
    @State private var oauthReview: NativeMCPOAuthReview?
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
                        if server.connected || server.connecting || manager.oauthProgress[server.id] != nil {
                            Button(server.connecting || manager.oauthProgress[server.id] != nil ? "Cancel connection" : "Disconnect") {
                                temporaryTokens.removeValue(forKey: server.id)
                                manager.cancelOAuthLocally(server.id)
                                Task { await manager.disconnect(server.id) }
                            }
                        } else if server.configuration.authentication == .oauth {
                            Button("Review sign-in access") { oauthReview = manager.beginOAuthReview(server.id) }
                        } else {
                            Button("Connect") {
                                let token = temporaryTokens.removeValue(forKey: server.id)
                                Task { await manager.connect(server.id, token: token) }
                            }
                        }
                    }
                    Text(server.configuration.endpoint.absoluteString).font(.caption).textSelection(.enabled)
                    Text(manager.oauthProgress[server.id] ?? server.status).font(.caption).foregroundStyle(Theme.textSecondary)
                    if server.configuration.authentication == .bearer && !server.connected && !server.connecting {
                        SecureField("Temporary access token", text: Binding(get: { temporaryTokens[server.id] ?? "" }, set: { temporaryTokens[server.id] = $0 }))
                            .textFieldStyle(.roundedBorder)
                        Text("Used only for this connection. Forgotten on disconnect or after one hour. Enter the token again after reopening Vera.")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    if server.configuration.authentication == .oauth && server.connected && manager.oauthProgress[server.id] == nil {
                        Button("Refresh sign-in") { Task { await manager.refreshOAuth(server.id) } }
                        Text("Sign-in lasts up to one hour. Refresh keeps the original access and expiry.")
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
        .sheet(item: $oauthReview) { review in
            NativeMCPOAuthReviewEditor(manager: manager, review: review)
        }
        .onDisappear { temporaryTokens.removeAll(); manager.cancelPendingOAuth() }
    }
}

struct NativeMCPOAuthReviewEditor: View {
    @ObservedObject var manager: NativeMCPManager
    let review: NativeMCPOAuthReview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to \(review.configuration.name)").font(.title2)
            Text("Review the service and access before continuing. Sign-in does not enable read tools; you choose those separately after connecting.")
                .font(.callout)
            Text("Service").font(.headline)
            Text(review.consent.resource.absoluteString).textSelection(.enabled)
            Text("Sign-in provider").font(.headline)
            Text(review.consent.issuer.absoluteString).textSelection(.enabled)
            Text("Requested access").font(.headline)
            ForEach(review.consent.scopes.sorted(), id: \.self) { Text($0).textSelection(.enabled) }
            DisclosureGroup("Connection destinations") {
                VStack(alignment: .leading, spacing: 8) {
                    destination("Sign-in page", review.consent.authorizationEndpoint)
                    destination("Token exchange", review.consent.tokenEndpoint)
                    destination("Service discovery", review.consent.protectedResourceMetadataURL)
                    destination("Sign-in discovery", review.consent.authorizationServerMetadataURL)
                    destination("Return address", review.consent.redirectURI)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Registered application").font(.caption).foregroundStyle(Theme.textSecondary)
                        Text(review.consent.clientID).font(.caption).textSelection(.enabled)
                    }
                }
            }
            Text("A private browser session is requested. Vera keeps authorization only in memory, for up to one hour. Disconnect ends this connection's access.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            if let progress = manager.oauthProgress[review.configuration.id] { Text(progress).font(.callout) }
            if let browser = manager.oauthFlows[review.configuration.id]?.browser as? NativeMCPOAuthFixtureBrowser {
                NativeMCPOAuthFixtureBrowserControls(browser: browser)
            }
            HStack {
                Spacer()
                Button("Cancel") { manager.cancelOAuthReview(review.configuration.id, reviewID: review.id); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sign in") {
                    Task {
                        await manager.signIn(review.configuration.id, reviewID: review.id)
                        if manager.oauthReviews[review.configuration.id] == nil { dismiss() }
                    }
                }.disabled(manager.oauthProgress[review.configuration.id] != nil)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520)
            .onDisappear { manager.cancelOAuthReview(review.configuration.id, reviewID: review.id) }
    }

    private func destination(_ name: String, _ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption).foregroundStyle(Theme.textSecondary)
            Text(url.absoluteString).font(.caption).textSelection(.enabled)
        }
    }
}

private struct NativeMCPOAuthFixtureBrowserControls: View {
    @ObservedObject var browser: NativeMCPOAuthFixtureBrowser
    var body: some View {
        if browser.waiting {
            Text("Test sign-in. No browser or real account is used.").font(.callout)
            Button("Complete test sign-in") { browser.complete() }
        }
    }
}
