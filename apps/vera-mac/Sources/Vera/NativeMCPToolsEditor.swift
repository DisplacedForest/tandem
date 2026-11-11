import SwiftUI

struct NativeMCPReadTestEditor: View {
    @ObservedObject var controller: NativeMCPReadTestController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Try a read").font(.title2)
                Text(verbatim: controller.record.server.name + " · " + controller.record.remoteName)
                    .font(.callout).foregroundStyle(Theme.textSecondary)
                Text("Run this enabled read directly. No model is used.").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if controller.usesPageURL {
                TextField("Page URL", text: input)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("mcp-read-page-url")
                    .disabled(controller.running)
            } else {
                Text("Arguments").font(.headline)
                TextEditor(text: input).font(.system(.body, design: .monospaced))
                    .frame(height: 100).border(Theme.textSecondary.opacity(0.3))
                    .accessibilityLabel("Read arguments as JSON").accessibilityIdentifier("mcp-read-arguments")
                    .disabled(controller.running)
                Text("Enter a JSON object, up to 16 KB.").font(.caption).foregroundStyle(Theme.textSecondary)
                DisclosureGroup("Argument format") {
                    ScrollView {
                        Text(verbatim: String(decoding: (try? controller.record.schema.piData()) ?? Data(), as: UTF8.self))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 110)
                }
            }
            if controller.running { ProgressView("Reading…").controlSize(.small) }
            if let error = controller.error { Text(verbatim: error).font(.callout).foregroundStyle(.orange) }
            if let result = controller.result {
                Text("Service response").font(.headline)
                ScrollView {
                    Text(verbatim: result.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("mcp-read-result")
                }.frame(minHeight: 100, maxHeight: 250)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Source").font(.caption).foregroundStyle(Theme.textSecondary)
                Text(verbatim: controller.record.server.endpoint.absoluteString)
                    .font(.caption).textSelection(.enabled).accessibilityIdentifier("mcp-read-source")
            }
            HStack {
                Spacer()
                Button(controller.running ? "Cancel" : "Close") { controller.close(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(controller.usesPageURL ? "Read page" : "Run read") { controller.run() }
                    .disabled(!controller.canRun).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 560)
            .onAppear { controller.checkCurrent(); if controller.invalidated { dismiss() } }
            .onChange(of: controller.invalidated) { _, invalidated in if invalidated { dismiss() } }
            .onDisappear { controller.close() }
    }

    private var input: Binding<String> {
        Binding(get: { controller.input }, set: { controller.updateInput($0) })
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
            Text("A private browser session is requested. Tandem keeps authorization only in memory, for up to one hour. Disconnect ends this connection's access.")
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
