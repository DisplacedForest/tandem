import Foundation

struct NativeMCPOAuthReview: Identifiable, Sendable {
    let id: UUID
    let configuration: NativeMCPServerConfiguration
    let consent: NativeMCPOAuthConsent
    let configurationGeneration: UUID
}

@MainActor
final class NativeMCPOAuthFlow {
    let owner: NativeMCPOAuthConnectionLifetime
    let browser: any NativeMCPOAuthBrowser
    let configurationGeneration: UUID
    var operation: Task<Void, Never>?
    init(owner: NativeMCPOAuthConnectionLifetime, browser: any NativeMCPOAuthBrowser, configurationGeneration: UUID) {
        self.owner = owner
        self.browser = browser
        self.configurationGeneration = configurationGeneration
    }
}

extension NativeMCPManager {
    func beginOAuthReview(_ id: String) -> NativeMCPOAuthReview? {
        refresh()
        guard !replacingConfiguration, let server = servers.first(where: { $0.id == id }), server.configuration.authentication == .oauth,
              !server.connected, !server.connecting, oauthFlows[id] == nil, let oauth = server.configuration.oauth else { return nil }
        do {
            let consent = try oauth.consent(serverID: id, expiresAt: Date().addingTimeInterval(oauthLifetimeForFixture ?? 3600))
            let review = NativeMCPOAuthReview(id: UUID(), configuration: server.configuration, consent: consent, configurationGeneration: configurationGeneration)
            oauthReviews[id] = review
            return review
        } catch { oauthProgress[id] = "The sign-in settings need to be reviewed."; return nil }
    }

    func signIn(_ id: String, reviewID: UUID) async {
        guard !replacingConfiguration, let review = oauthReviews[id], review.id == reviewID, review.configurationGeneration == configurationGeneration,
              oauthFlows[id] == nil, servers.first(where: { $0.id == id })?.configuration == review.configuration else { return }
        guard let owner = try? NativeMCPOAuthConnectionLifetime(configuration: review.configuration, consent: review.consent) else { return }
        guard authority.access.setOAuthOwner(owner) else { owner.cancel(); return }
        let flow = NativeMCPOAuthFlow(owner: owner, browser: oauthBrowserFactory(), configurationGeneration: configurationGeneration)
        oauthFlows[id] = flow
        owner.onCancel { [weak self, weak flow, weak owner] in
            Task { @MainActor in
                guard let self, let flow, let owner else { return }
                self.clearOAuthFlow(id, flow: flow)
                await self.authority.disconnect(id, status: "Sign-in ended. Review access and sign in again.", oauth: owner)
                self.refresh()
            }
        }
        oauthProgress[id] = "Checking the sign-in service"
        let operation = Task { @MainActor [weak self] in
            guard let self else { owner.cancel(); return }
            await self.performOAuthSignIn(id, flow: flow)
        }
        flow.operation = operation
        await withTaskCancellationHandler { await operation.value } onCancel: { owner.cancel(); operation.cancel() }
    }

    private func performOAuthSignIn(_ id: String, flow: NativeMCPOAuthFlow) async {
        do {
            let session = try await NativeMCPOAuthSession.discover(consent: flow.owner.consent, transport: oauthTransport)
            try requireCurrent(id, flow: flow)
            try flow.owner.install(session)
            let url = try await session.authorizationURL(generation: flow.owner.consent.generation)
            try requireCurrent(id, flow: flow)
            oauthProgress[id] = "Finish signing in in the private browser window"
            let callback = try await flow.browser.authenticate(url: url, callback: flow.owner.consent.redirectURI)
            try requireCurrent(id, flow: flow)
            oauthProgress[id] = "Completing sign-in"
            let lease = try await session.complete(callback: callback, generation: flow.owner.consent.generation)
            try requireCurrent(id, flow: flow)
            oauthProgress[id] = "Discovering approved read tools"
            await authority.connect(id, authorization: lease, oauth: flow.owner)
            try requireCurrent(id, flow: flow)
            guard authority.access.snapshot().contains(where: { $0.id == id && $0.connected }) else { throw NativeMCPOAuthError.network }
            flow.operation = nil
            oauthReviews.removeValue(forKey: id)
            oauthProgress.removeValue(forKey: id)
            refresh()
        } catch { await failOAuth(id, flow: flow) }
    }

    func refreshOAuth(_ id: String) async {
        guard let flow = oauthFlows[id], flow.operation == nil, let session = flow.owner.session,
              authority.access.snapshot().contains(where: { $0.id == id && $0.connected }), isCurrent(id, flow: flow) else { return }
        oauthProgress[id] = "Refreshing sign-in"
        let operation = Task { @MainActor [weak self] in
            guard let self else { flow.owner.cancel(); return }
            do {
                guard await self.authority.suspendOAuth(id, owner: flow.owner) else { throw NativeMCPOAuthError.cancelled }
                try self.requireCurrent(id, flow: flow)
                let lease = try await session.refresh(generation: flow.owner.consent.generation)
                try self.requireCurrent(id, flow: flow)
                await self.authority.connect(id, authorization: lease, oauth: flow.owner)
                try self.requireCurrent(id, flow: flow)
                guard self.authority.access.snapshot().contains(where: { $0.id == id && $0.connected }) else { throw NativeMCPOAuthError.network }
                flow.operation = nil
                self.oauthProgress.removeValue(forKey: id)
                self.refresh()
            } catch { await self.failOAuth(id, flow: flow) }
        }
        flow.operation = operation
        await withTaskCancellationHandler { await operation.value } onCancel: { flow.owner.cancel(); operation.cancel() }
    }

    func cancelOAuth(_ id: String) {
        let owner = authority.access.oauthOwner(id)
        cancelOAuthLocally(id)
        guard let owner else { return }
        Task { [weak self, authority] in
            await authority.disconnect(id, oauth: owner)
            self?.refresh()
        }
    }

    func cancelOAuthReview(_ id: String, reviewID: UUID) {
        guard oauthReviews[id]?.id == reviewID else { return }
        cancelOAuth(id)
    }

    func cancelPendingOAuth() {
        let ids = Set(oauthReviews.keys).union(oauthFlows.filter { $0.value.operation != nil }.keys)
        for id in ids { cancelOAuth(id) }
    }

    func cancelOAuthLocally(_ id: String) {
        oauthReviews.removeValue(forKey: id)
        oauthProgress.removeValue(forKey: id)
        authority.access.oauthOwner(id)?.cancel()
        if let flow = oauthFlows.removeValue(forKey: id) {
            flow.owner.cancel()
            flow.browser.cancel()
            flow.operation?.cancel()
        }
    }

    func clearOAuthFlow(_ id: String, flow: NativeMCPOAuthFlow) {
        guard oauthFlows[id] === flow else { return }
        oauthFlows.removeValue(forKey: id)
        oauthReviews.removeValue(forKey: id)
        oauthProgress.removeValue(forKey: id)
        flow.browser.cancel()
        flow.operation?.cancel()
        flow.owner.cancel()
    }

    func replaceConfiguration(_ servers: [NativeMCPServerConfiguration]) async {
        configurationGeneration = UUID()
        replacingConfiguration = true
        let generation = configurationGeneration
        defer { if configurationGeneration == generation { replacingConfiguration = false } }
        for id in Set(oauthReviews.keys).union(oauthFlows.keys) { cancelOAuthLocally(id) }
        for server in authority.access.snapshot() {
            await authority.disconnect(server.id)
            guard configurationGeneration == generation else { return }
        }
        authority.access.replaceServers(servers)
        refresh()
    }

    private func isCurrent(_ id: String, flow: NativeMCPOAuthFlow) -> Bool {
        oauthFlows[id] === flow && flow.owner.isActive && flow.configurationGeneration == configurationGeneration
            && authority.access.oauthOwner(id) === flow.owner
            && authority.access.snapshot().contains(where: { $0.configuration == flow.owner.configuration })
    }

    private func requireCurrent(_ id: String, flow: NativeMCPOAuthFlow) throws {
        try Task.checkCancellation()
        guard isCurrent(id, flow: flow) else { throw NativeMCPOAuthError.cancelled }
    }

    private func failOAuth(_ id: String, flow: NativeMCPOAuthFlow) async {
        flow.owner.cancel()
        guard oauthFlows[id] === flow else { return }
        clearOAuthFlow(id, flow: flow)
        await authority.disconnect(id, status: "Sign-in did not finish. Review access and try again.", oauth: flow.owner)
        refresh()
    }
}
