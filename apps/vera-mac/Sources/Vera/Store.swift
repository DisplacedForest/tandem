import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ChatStore: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var selectedID: String? {
        didSet { if pendingSourceNotice?.conversationID != selectedID { pendingSourceNotice = nil } }
    }
    @Published var pendingSourceNotice: NativeMemorySourceNotice?
    @Published var memorySettingsNotice: String?
    @Published var classicChatRequest = 0
    @Published var draft: String = ""
    @Published private(set) var veraThreadID: String?
    private(set) var lastFocusedConversationID: String?
    private var drafts: [String: String] = [:]
    static let veraThreadOriginType = "assistant"
    static let veraThreadOriginID = "vera"
    @Published var section: AppSection = .chat
    @Published var settingsTab: SettingsTab = .connection  // selected Settings tab; deep links set it before opening Settings
    @Published var agenticPane: AgenticPane = .canvas   // which Agentic surface the sidebar shows
    @Published var agenticFlowID: String?
    @Published var pulseCards: [PulseCard] = []
    @Published var pulseVeins: [PulseVein] = []   // pinned ambient veins, populated from vera-api
    @Published var memoryRecords: [NativeMemoryRecord] = []
    @Published var memoryLibraryRevision = 0
    var nativeMemoryNow: () -> Date = { Date() }
    private var reloadingNativeMemory = false
    @Published var memoryProposals: [NativeMemoryProposal] = []
    @Published var inspectedMemoryRevision: Int?
    @Published var inspectedMemory: NativeMemoryRecord?
    @Published var memoryServiceState: NativeMemoryServiceState = .off
    @Published var memoryEndpointStatus: NativeMemoryEndpointStatus = .notConfigured
    @Published var memoryIndexingProgress: NativeMemoryIndexingProgress?
    @Published var memoryVectorStatus: NativeMemoryVectorStatus?
    var memoryBackfillPending = false
    @Published var memoryRetrievalTraces: [String: NativeMemoryRetrievalTrace] = [:]
    @Published var inspectedMemoryTrace: NativeMemoryRetrievalTrace?
    @Published private(set) var queuedMemoryTurns: [NativeMemoryQueuedTurn] = []
    private var drainingMemoryQueue = false
    private var memoryQueueStatusMessage: String?
    static let queuedMemoryTurnLimit = 20
    @Published var pendingHighlightMessageID: UUID?
    @Published var memoryGroomOutcome: NativeMemoryGroomOutcome?
    @Published var streamStatus: String?     // live tool/progress line while Vera is thinking
    @Published var generating = false        // true for the whole turn (drives the living flame mark)
    @Published var groundingStatus: [String: KnowledgeGroundingStatus] = [:]
    @Published var pulseRatings: [String: String] = [:]   // Pulse cardID → "up"/"down"
    @Published var messageRatings: [UUID: String] = [:]   // chat messageID → "up"/"down"
    @Published var bookmarkedPulseIDs: Set<String> = []
    @Published var readPulseIDs: Set<String> = []         // cards whose detail this person has opened
    @Published var restoreState: [String: String] = [:]   // "<cardID>:<opIndex>" → running/done/failed
    @Published var actionState: [String: String] = [:]    // Pulse cardID → running/done/dismissed/failed
    @Published var digestItemState: [String: String] = [:] // "<cardID>:<itemID>" → pending/running/approved/skipped/failed
    @Published var pulseContinuation: [String: PulseContinuationState] = [:]
    @Published var pulseDetail: PulseCard? = nil    // open card detail (lifted here so the sidebar can dismiss it)
    @Published var pulseVeinDetail: PulseVein? = nil // open vein overlay (ditto)
    @Published var focusTick: Int = 0         // bump to move the cursor into the composer
    @Published var attachments: [Attachment] = []   // pending composer attachments (images/docs)
    @Published var attachmentError: String?
    @Published var pendingSendDecision: PendingSendDecision?
    @Published var activeArtifact: Artifact?  // the artifact shown in the Canvas panel
    @Published var showCanvas: Bool = false
    @Published var artifactLibrary: [Artifact] = []   // persisted across sessions
    @Published var chatConfigurationError: String?
    @Published var lastRequestTrace: NativeRequestTrace?
    @Published var parameterRejection: NativeParameterRejectionPrompt?
    @Published var pendingToolConfirmation: NativeToolConfirmationRequest?

    private var client: VeraAPIClient?
    private var nativeConfig: NativeChatConfig?
    private var nativeTransport: (any NativeChatTransport)?
    private var titleGenerationInFlight: Set<String> = []
    private var titleGenerationAttempted: Set<String> = []
    var titleGenerationTimeout: Duration = .seconds(20)
    var generatesConversationTitles = false
    private let nativeTransportFactory: (NativeChatConfig) -> (any NativeChatTransport)?
    private var nativeSystemPrompt: String
    private var nativePersonaID: String?
    private var nativeOwnerName: String?
    @Published private(set) var assistantName: String = ConfigStore.defaultAssistantName
    private var nativeEnabledToolIDs: Set<String>
    private var nativeCapabilityOverrides: [String: ModelCapabilityProfile]
    private var visionBridgeConfig: VisionBridgeConfig?
    private let visionBridgeTransportFactory: ((VisionBridgeConfig) -> any NativeChatTransport)?
    private var turnMemorySelections: [UUID: [NativeMemoryRanked]] = [:]
    private(set) var nativeMemorySettings: NativeMemorySettings
    private(set) var nativeRules: NativeRules
    @Published var rulesNotice: String?
    let turnCommandReasonSource = NativeCommandReasonSource()
    let nativeRuleSource = NativeRuleSource()
    let turnDeclineSource = NativeDeclineSource()
    private(set) var nativeMemoryService: (any NativeMemoryServing)?
    let nativeMCP: NativeMCPManager?
    private var nativeToolRegistry: NativeToolRegistry
    private let usesInjectedToolRegistry: Bool
    private(set) var capabilityDeclarations: [NativeToolDeclaration]
    private var toolConfirmationContinuation: CheckedContinuation<Bool, Never>?
    let repository: (any ChatRepository)?
    private let repositoryInitializationError: String?
    let nativeTaskRepository: (any NativeTaskRepository)?
    let nativeTaskService: NativeTaskHandoffService?
    let nativeTaskBroker: NativeTaskGenerationBroker?
    let nativeTaskEngine: NativeTaskEngineSelection
    let nativeTaskLocalEngine: NativeTaskLocalEngine?
    let nativeWorkerIdentity: NativeWorkerIdentitySource
    let nativeSearchAvailable: @Sendable () -> Bool
    let nativeTaskConfiguration: NativeTaskConfiguration?
    let nativeTaskEnrollment: NativeTaskProfileBinding?
    var nativeTaskRecoveryLoop: Task<Void, Never>?
    var nativeTaskGenerationLoop: Task<Void, Never>?
    var nativeTaskTrackingLoop: Task<Void, Never>?
    var nativeTaskTracker: NativeTaskTracker?
    let nativeTaskTrackingClient: NativeTaskClient
    @Published var nativeTaskReferences: [NativeTaskReference] = []
    @Published var grantError: String?
    @Published var grantConsentTick = 0
    let nativeGrantSource = NativeFolderGrantSource()
    @Published var schedules: [NativeSchedule] = []
    @Published var scheduleRuns: [String: [NativeScheduleRun]] = [:]
    @Published var scheduleError: String?
    @Published var menuBarPreference: Bool?
    var nativeScheduleStore: NativeScheduleStore?
    var nativeScheduler: NativeScheduler?
    var nativeSchedulerLoop: Task<Void, Never>?
    let attachmentStore: NativeAttachmentStore
    private let artifactPersistenceEnabled: Bool
    var nativeKnowledgeQuery: @Sendable (URL, String, [String]) async -> KnowledgeClient.QueryResult = { base, query, collections in
        await KnowledgeClient(base: base).query(query, collections: collections)
    }
    private let pulseFeedProvider: (any PulseFeedProviding)?
    var isLive: Bool { nativeTransport != nil && repository != nil }
    var canSubmitChat: Bool { repository != nil }
    @Published var conversationTurns: [NativeConversationTurn] = []
    @Published var turnStatuses: [UUID: String] = [:]
    @Published var turnConfirmations: [UUID: NativeToolConfirmationRequest] = [:]
    var turnConfirmationTokens: [UUID: UUID] = [:]
    var turnExecutions: [UUID: NativeTurnExecution] = [:]
    static let turnProcessIdentity = UUID().uuidString
    var suspendsTurnScheduling = false
    var isSchedulingTurns = false
    var conversationTurnLoop: Task<Void, Never>?
    var conversationTurnToken: [Int64]?
    var dirtyTurnConversations: Set<String> = []
    var conversationTurnHeaders: [UUID: NativeConversationTurnHeader] = [:]
    var isPulseConfigured: Bool { client != nil }
    var mediaBase: String? { client?.base.absoluteString }
    var currentNativeConfig: NativeChatConfig? { nativeConfig }

    init(veraAPI: VeraAPIClient? = nil,
         nativeConfig: NativeChatConfig?, nativeTransport: (any NativeChatTransport)?,
         repository: (any ChatRepository)?, repositoryError: String? = nil,
         nativeTransportFactory: @escaping (NativeChatConfig) -> (any NativeChatTransport)? = { NativeChatClient.foreground(config: $0) },
         nativeSystemPrompt: String = NativeChatSettings.defaultSystemPrompt,
         nativePersonaID: String? = nil,
         nativeOwnerName: String? = nil,
         nativeAssistantName: String = ConfigStore.defaultAssistantName,
         nativeEnabledToolIDs: Set<String> = [],
         nativeCapabilityOverrides: [String: ModelCapabilityProfile] = [:],
         visionBridgeConfig: VisionBridgeConfig? = nil,
         visionBridgeTransportFactory: ((VisionBridgeConfig) -> any NativeChatTransport)? = nil,
         nativeMemorySettings: NativeMemorySettings = .fresh,
         nativeMemoryService: (any NativeMemoryServing)? = nil,
         nativeRules: NativeRules = .defaults,
         nativeToolRegistry: NativeToolRegistry? = nil,
         nativeMCP: NativeMCPManager? = nil,
         capabilityDeclarations: [NativeToolDeclaration] = [],
         pulseFeed: (any PulseFeedProviding)? = nil,
         attachmentStore: NativeAttachmentStore = NativeAttachmentStore(),
         sweepOrphanedAttachments: Bool = false,
         nativeTaskConfiguration: NativeTaskConfiguration? = nil,
         nativeTaskClient: NativeTaskClient? = nil,
         nativeResearchOptions: NativeTaskResearchOptions = .standard,
         nativeTaskEnrollment: NativeTaskProfileBinding? = nil,
         nativeSearchAvailable: @escaping @Sendable () -> Bool = { NativeWebSearch.resolvedBase() != nil },
         artifactPersistenceEnabled: Bool = true) {
        self.nativeSearchAvailable = nativeSearchAvailable
        self.artifactPersistenceEnabled = artifactPersistenceEnabled
        let localEngine: NativeTaskLocalEngine?
        let identity = NativeWorkerIdentitySource()
        identity.update(assistantName: nativeAssistantName, ownerName: nativeOwnerName)
        nativeWorkerIdentity = identity
        if nativeTaskClient == nil, let local = repository as? LocalChatRepository {
            localEngine = NativeTaskLocalEngine.workers(database: local.database,
                search: .live(base: { NativeWebSearch.resolvedBase() }), identity: { identity.current })
        } else {
            localEngine = nil
        }
        nativeTaskLocalEngine = localEngine
        let nativeTaskClient = nativeTaskClient ?? localEngine?.client ?? .live
        let taskEngine = NativeTaskEngineSelection(localEngine != nil ? NativeTaskLocalEngine.identity.base : veraAPI?.base)
        self.nativeTaskEngine = taskEngine
        self.nativeTaskTrackingClient = nativeTaskClient
        self.nativeTaskConfiguration = nativeTaskConfiguration
        self.nativeTaskEnrollment = nativeTaskEnrollment
        self.nativeTaskRepository = repository as? any NativeTaskRepository
        if let taskRepository = repository as? any NativeTaskRepository {
            nativeTaskService = NativeTaskHandoffService(repository: taskRepository, client: nativeTaskClient,
                                                       researchOptions: nativeResearchOptions, configuredBase: { taskEngine.base })
        } else {
            nativeTaskService = nil
        }
        if let taskRepository = repository as? any NativeTaskGenerationRepository, let nativeTaskConfiguration {
            nativeTaskBroker = NativeTaskGenerationBroker(repository: taskRepository, client: nativeTaskClient,
                configuredBase: { taskEngine.base },
                isProfileAvailable: { await nativeTaskConfiguration.isAvailable($0) },
                generate: { profile, job in
                    let config = try await nativeTaskConfiguration.load(profile)
                    return try await NativeTaskProvider.complete(config: config, binding: profile, job: job)
                })
        } else {
            nativeTaskBroker = nil
        }
        self.client = veraAPI
        self.nativeConfig = nativeConfig
        self.nativeTransport = nativeTransport
        self.nativeTransportFactory = nativeTransportFactory
        self.nativeSystemPrompt = nativeSystemPrompt
        self.nativePersonaID = nativePersonaID
        self.nativeOwnerName = nativeOwnerName
        self.assistantName = nativeAssistantName
        self.nativeEnabledToolIDs = nativeEnabledToolIDs
        self.nativeCapabilityOverrides = nativeCapabilityOverrides
        self.visionBridgeConfig = visionBridgeConfig
        self.visionBridgeTransportFactory = visionBridgeTransportFactory
        self.nativeMemorySettings = nativeMemorySettings
        self.nativeMemoryService = nativeMemoryService
        self.nativeRules = nativeRules
        nativeRuleSource.setGlobal(nativeRules)
        self.capabilityDeclarations = capabilityDeclarations
        self.nativeMCP = nativeMCP
        self.nativeToolRegistry = nativeToolRegistry
            ?? ChatStore.buildToolRegistry(capabilityDeclarations, attachments: attachmentStore)
        usesInjectedToolRegistry = nativeToolRegistry != nil
        self.repository = repository
        self.repositoryInitializationError = repositoryError
        self.pulseFeedProvider = pulseFeed
        self.attachmentStore = attachmentStore
        chatConfigurationError = repositoryError
        selectedID = conversations.first?.id
        loadArtifacts()

        if sweepOrphanedAttachments, let repository,
           let referenced = try? repository.referencedAttachmentFileNames() {
            let store = attachmentStore
            let candidates = store.orphanCandidates(keeping: referenced)
            if !candidates.isEmpty {
                Task.detached(priority: .utility) { store.removeOrphans(candidates) }
            }
        }
    }

    // MARK: - Canvas / artifacts

    private static var artifactsURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vera", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("artifacts.json")
    }

    func loadArtifacts() {
        guard artifactPersistenceEnabled else { return }
        if let d = try? Data(contentsOf: Self.artifactsURL),
           let arr = try? JSONDecoder().decode([Artifact].self, from: d) {
            artifactLibrary = arr
        }
    }

    func openArtifact(_ a: Artifact) {
        activeArtifact = a
        showCanvas = true
        saveArtifact(a)
    }

    func closeCanvas() { showCanvas = false }

    /// Local edit of the open artifact's source — live-updates the preview and persists.
    func updateActiveArtifact(content: String) {
        guard var a = activeArtifact else { return }
        a.content = content
        a.updatedAt = Date()
        activeArtifact = a
        saveArtifact(a)
    }

    private func saveArtifact(_ a: Artifact) {
        guard artifactPersistenceEnabled else { return }
        if let i = artifactLibrary.firstIndex(where: { $0.id == a.id }) { artifactLibrary[i] = a }
        else { artifactLibrary.insert(a, at: 0) }
        try? JSONEncoder().encode(artifactLibrary).write(to: Self.artifactsURL)
    }

    deinit {
        conversationTurnLoop?.cancel()
        nativeTaskRecoveryLoop?.cancel()
        nativeTaskGenerationLoop?.cancel()
        nativeTaskTrackingLoop?.cancel()
        if let nativeTaskTracker { Task { await nativeTaskTracker.stop() } }
        if let engine = nativeTaskLocalEngine { Task { await engine.stop() } }
    }

    /// Standalone constructor (screenshots / `Shot`): loads config and builds its own deps.
    convenience init() {
        let configStore = ConfigStore()
        let native = configStore.nativeResolved
        self.init(
            veraAPI: VeraAPIClient.resolved(model: native?.model ?? ""),
            nativeConfig: native,
            nativeTransport: native.map { NativeChatClient.foreground(config: $0) },
            repository: try? LocalChatRepository(inMemory: true),
            nativeOwnerName: configStore.ownerName,
            nativeAssistantName: configStore.assistantName,
            nativeMemorySettings: .fresh)
    }

    static func buildToolRegistry(
        _ declarations: [NativeToolDeclaration],
        attachments: NativeAttachmentStore = NativeAttachmentStore()
    ) -> NativeToolRegistry {
        let base: @Sendable () -> URL? = { VeraAPIClient.resolvedBase() }
        let imageBase: @Sendable () -> URL? = { NativeImageTools.resolvedBase() }
        return NativeToolRegistry(
            definitions: NativeRemindersTools.definitions(service: RemindersBridge.shared)
                + NativeWebTools.definitions(searchBase: { NativeWebSearch.resolvedBase() })
                + NativeImageTools.definitions(base: imageBase, attachments: attachments)
                + NativeCapabilityTools.definitions(declarations, base: base))
    }

    static var builtInToolNames: Set<String> {
        Set(buildToolRegistry([]).definitions.map(\.name)).union([NativeTaskTools.toolName]).union(NativeFolderTools.toolNames).union(NativeCommandTools.toolNames)
    }

    func reloadCapabilityTools(_ declarations: [NativeToolDeclaration]) {
        capabilityDeclarations = declarations
        guard !usesInjectedToolRegistry else { return }
        nativeToolRegistry = ChatStore.buildToolRegistry(declarations, attachments: attachmentStore)
    }

    func awaitToolConfirmation(_ activity: NativeToolActivity) async -> Bool {
        resolveToolConfirmation(false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                toolConfirmationContinuation = continuation
                pendingToolConfirmation = NativeToolConfirmationRequest(activity: activity)
            }
        } onCancel: {
            Task { @MainActor in self.resolveToolConfirmation(false) }
        }
    }

    func resolveToolConfirmation(_ approved: Bool) {
        if let pending = pendingToolConfirmation,
           let messageID = turnConfirmations.first(where: { $0.value == pending })?.key {
            resolveTurnConfirmation(messageID, approved: approved, requestID: pending.id)
            return
        }
        guard let continuation = toolConfirmationContinuation else { return }
        toolConfirmationContinuation = nil
        pendingToolConfirmation = nil
        continuation.resume(returning: approved)
    }

    func adoptNative(
        _ cfg: NativeChatConfig,
        systemPrompt: String = NativeChatSettings.defaultSystemPrompt,
        activePersonaID: String? = nil,
        ownerName: String? = nil,
        assistantName: String? = nil,
        enabledToolIDs: Set<String>? = nil,
        capabilityOverrides: [String: ModelCapabilityProfile]? = nil,
        visionBridge: VisionBridgeConfig? = nil,
        memorySettings: NativeMemorySettings? = nil,
        memoryService: (any NativeMemoryServing)? = nil,
        rules: NativeRules? = nil,
        capabilityDeclarations: [NativeToolDeclaration]? = nil
    ) {
        nativeConfig = cfg
        nativeTransport = nativeTransportFactory(cfg)
        nativeSystemPrompt = systemPrompt
        nativePersonaID = activePersonaID
        nativeOwnerName = ownerName
        if let assistantName { adoptAssistantName(assistantName) }
        if let enabledToolIDs { updateNativeToolConsent(enabledToolIDs) }
        if let capabilityOverrides { nativeCapabilityOverrides = capabilityOverrides }
        visionBridgeConfig = visionBridge
        if let memorySettings { nativeMemorySettings = memorySettings }
        nativeMemoryService = memoryService
        if let rules { updateNativeRules(rules) }
        if let capabilityDeclarations { reloadCapabilityTools(capabilityDeclarations) }
        client = VeraAPIClient.resolved(model: cfg.model)
        if nativeTaskLocalEngine == nil { nativeTaskEngine.set(client?.base) }
        chatConfigurationError = nil
        Task { await connect() }
    }

    func connect() async {
        stashDraft()
        let previousSelected = selectedID
        let previousSection = section
        let unsaved = conversations.filter { !$0.isPersisted && $0.messages.isEmpty }
        if let repository {
            do {
                conversations = try repository.listConversations()
                chatConfigurationError = nil
            } catch {
                conversations = []
                chatConfigurationError = "Local history couldn't open: \(error.localizedDescription)"
            }
        } else {
            conversations = []
            chatConfigurationError = repositoryInitializationError ?? "Local history couldn't open"
        }
        for convo in unsaved.reversed() where !conversations.contains(where: { $0.id == convo.id }) {
            conversations.insert(convo, at: 0)
        }
        ensureVeraThread()
        syncGrantSource()
        syncRuleSource()
        if let previousSelected, conversations.contains(where: { $0.id == previousSelected }) {
            select(previousSelected)
            section = previousSection
        } else {
            newConversation()
        }
        resumeConversationTurns()
        startNativeTaskRecovery()
        startNativeScheduler()
        await refreshPulse()
        reloadNativeMemory()
        runMemoryGroom()
        runNativeMemoryMaintenance()
        indexApprovedMemoryIfNeeded()
        startReconcileLoop()
        startMemoryGroomLoop()
    }

    /// Re-fetch the Pulse feed from vera-api (its standalone store). Reflects adds/deletes,
    /// and restores persisted bookmark state.
    func refreshPulse() async {
        guard let client else { return }
        async let cardsTask = client.fetchPulseCards()
        async let veinsTask = client.fetchPulseVeins()
        let (cards, veins) = await (cardsTask, veinsTask)
        pulseCards = cards
        pulseVeins = veins   // empty when vera-api is unconfigured or returns none
        bookmarkedPulseIDs = Set(cards.filter { $0.status == "bookmarked" }.map { $0.id })
        readPulseIDs = Set(cards.filter { $0.read }.map { $0.id })   // per-row read state
    }

    /// Mark a card read the moment its detail opens. Optimistic (insert + decrement the
    /// chip's unread now), then persist to vera-api and reconcile the counts on refresh. Idempotent.
    func markPulseRead(_ card: PulseCard) {
        guard !readPulseIDs.contains(card.id) else { return }
        readPulseIDs.insert(card.id)
        if let i = pulseVeins.firstIndex(where: { $0.kind == card.kind }), pulseVeins[i].unread > 0 {
            pulseVeins[i].unread -= 1
        }
        guard let client else { return }
        Task {
            await client.markPulseRead(id: card.id)
            await refreshPulse()   // reconcile unread counts + max severity from the server
        }
    }

    // MARK: - Pulse tiers: pinned ambient veins vs the research feed

    /// Kinds that have a pinned vein — every other kind falls into the research feed.
    private var veinedKinds: Set<String> { Set(pulseVeins.map { $0.kind }) }

    /// The research feed: cards whose kind has no pinned vein (research + any unknown kind).
    var feedCards: [PulseCard] { pulseCards.filter { !veinedKinds.contains($0.kind) } }

    /// Active cards for one vein (matched by kind), newest first as the store returns them.
    func veinCards(_ kind: String) -> [PulseCard] { pulseCards.filter { $0.kind == kind } }

    /// A vein's cards grouped by category in fixed order (Vera/Infra/Health/Updates),
    /// newest-first within each group (store order is preserved). Empty groups are dropped.
    func veinCardsByCategory(_ kind: String) -> [(PulseCategory, [PulseCard])] {
        let cards = veinCards(kind)
        return PulseCategory.allCases.compactMap { cat in
            let group = cards.filter { PulseCategory.of($0) == cat }
            return group.isEmpty ? nil : (cat, group)
        }
    }

    /// Restore or reject one grooming op, routed to the correct store by `op.store`.
    /// Restore = one-time undo; Reject = undo + don't-redo (suppressed next run). Optimistic state,
    /// then reconcile the feed. A "stale" result means a later run already changed the target.
    func restoreMemoryOp(_ card: PulseCard, _ op: GroomOp) { decideGroomOp(card, op, mode: "restore") }
    func rejectOp(_ card: PulseCard, _ op: GroomOp) { decideGroomOp(card, op, mode: "reject") }

    private func decideGroomOp(_ card: PulseCard, _ op: GroomOp, mode: String) {
        guard let client else { return }
        let key = "\(card.id):\(op.index)"
        restoreState[key] = "running"
        Task {
            let state = await client.decideGroomOp(store: op.store, mode: mode,
                                                   cardID: card.id, opIndex: op.index)
            restoreState[key] = (state == "done") ? (mode == "reject" ? "rejected" : "done") : state
            await refreshPulse()
        }
    }

    /// Approve/Reject a flagged-for-review proposal (a digest item) inline — reuses the
    /// digest decision path; Approve commits the staged action, Reject suppresses it.
    func decideProposal(_ card: PulseCard, _ item: PulseDigestItem, approve: Bool) {
        decideDigestItem(card, item, approve: approve)
    }

    private var reconcileStarted = false
    private func startReconcileLoop() {
        guard !reconcileStarted else { return }
        reconcileStarted = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.reconcile() }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard let self else { return }
                await self.reconcile()
            }
        }
    }

    private func reconcile() async {
        await refreshPulse()
    }

    // MARK: - Bookmark + feedback

    func bookmarkPulse(_ card: PulseCard) {
        let turningOn = !bookmarkedPulseIDs.contains(card.id)
        if turningOn { bookmarkedPulseIDs.insert(card.id) } else { bookmarkedPulseIDs.remove(card.id) }
        guard let client else { return }
        Task { await client.setPulseBookmark(id: card.id, on: turningOn) }
    }

    /// Thumbs-up/down a Pulse card. Tapping the active thumb again clears it (no record on clear).
    func ratePulse(_ card: PulseCard, _ sentiment: String) {
        if pulseRatings[card.id] == sentiment { pulseRatings[card.id] = nil; return }
        pulseRatings[card.id] = sentiment
        guard let client else { return }
        Task {
            await client.postFeedback([
                "kind": "pulse", "sentiment": sentiment, "topic": card.title, "title": card.title,
                "content": card.body, "chat_id": card.id, "model": nativeConfig?.model ?? "",
            ])
        }
    }

    /// Confirm a Pulse action card → execute it server-side, then reflect the outcome.
    func confirmAction(_ card: PulseCard) {
        guard let action = card.action, let client else { return }
        actionState[card.id] = "running"
        Task {
            let out = await client.commitAction(token: action.token)
            if let out, (out["ok"] as? Bool) == true {
                actionState[card.id] = "done"
            } else {
                actionState[card.id] = "failed: " + ((out?["error"] as? String) ?? "error")
            }
        }
    }

    /// Dismiss a Pulse action card → drop the staged action; nothing runs.
    func dismissAction(_ card: PulseCard) {
        actionState[card.id] = "dismissed"
        guard let action = card.action, let client else { return }
        Task { await client.dismissAction(token: action.token) }
    }

    /// The live state of one digest item (local optimistic state overrides the stored state).
    func digestState(_ card: PulseCard, _ item: PulseDigestItem) -> String {
        digestItemState["\(card.id):\(item.itemID)"] ?? item.state
    }

    /// Approve (request) or skip one item of a digest card.
    func decideDigestItem(_ card: PulseCard, _ item: PulseDigestItem, approve: Bool) {
        guard let client else { return }
        let key = "\(card.id):\(item.itemID)"
        digestItemState[key] = "running"
        Task {
            let ok = await client.decideDigestItem(cardID: card.id, itemID: item.itemID, approve: approve)
            digestItemState[key] = ok ? (approve ? "approved" : "skipped") : "failed"
            // A successful apply changes the system: re-check so the card reflects reality
            // (the pending count drops) without waiting for the daily scheduled check.
            if ok, approve, card.category == "update" {
                await client.checkUpdatesNow()
                await refreshPulse()
            }
        }
    }

    /// Force a fresh stack-updates check, then refresh the feed (the updates card's "Check now").
    func checkUpdatesNow() {
        guard let client else { return }
        Task {
            await client.checkUpdatesNow()
            await refreshPulse()
        }
    }

    /// Go to the Pulse feed, dismissing any open card/vein detail. Lets the sidebar Pulse
    /// button act as a "back to feed" from anywhere inside Pulse.
    func goToPulse() {
        section = .pulse
        pulseDetail = nil
        pulseVeinDetail = nil
    }

    /// Approve-all / skip-all the still-pending items of a digest card.
    func decideDigestAll(_ card: PulseCard, approve: Bool) {
        guard let client else { return }
        for item in card.items where digestState(card, item) == "pending" {
            digestItemState["\(card.id):\(item.itemID)"] = "running"
        }
        Task {
            await client.decideDigestAll(cardID: card.id, approve: approve)
            for item in card.items where digestItemState["\(card.id):\(item.itemID)"] == "running" {
                digestItemState["\(card.id):\(item.itemID)"] = approve ? "approved" : "skipped"
            }
        }
    }

    /// Thumbs-up/down a chat response → preference data for later post-training (RLHF/DPO).
    func rateMessage(_ message: Message, in convo: Conversation, _ sentiment: String) {
        if messageRatings[message.id] == sentiment { messageRatings[message.id] = nil; return }
        messageRatings[message.id] = sentiment
    }

    func isVeraThread(_ id: String?) -> Bool { id != nil && id == veraThreadID }

    func adoptAssistantName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        assistantName = trimmed.isEmpty ? ConfigStore.defaultAssistantName : trimmed
        nativeWorkerIdentity.update(assistantName: assistantName, ownerName: nativeOwnerName)
        retitleVeraThread()
    }

    private func retitleVeraThread() {
        guard let veraThreadID, let index = conversations.firstIndex(where: { $0.id == veraThreadID }),
              conversations[index].title != assistantName else { return }
        conversations[index].title = assistantName
        try? repository?.saveConversation(conversations[index])
    }

    func ensureVeraThread() {
        if let existing = conversations.first(where: { $0.originType == Self.veraThreadOriginType && $0.originID == Self.veraThreadOriginID }) {
            veraThreadID = existing.id
            retitleVeraThread()
            return
        }
        guard let repository else { veraThreadID = nil; return }
        var thread = Conversation(id: UUID().uuidString, title: assistantName, messages: [], updatedAt: Date(),
                                  originType: Self.veraThreadOriginType, originID: Self.veraThreadOriginID)
        do {
            try repository.saveConversation(thread)
            thread.isPersisted = true
            conversations.append(thread)
            veraThreadID = thread.id
        } catch {
            veraThreadID = nil
            chatConfigurationError = "The Vera thread couldn't be created: \(error.localizedDescription)"
        }
    }

    func openVeraThread() {
        guard let veraThreadID else { section = .vera; return }
        stashDraft()
        section = .vera
        selectedID = veraThreadID
        draft = drafts[veraThreadID] ?? ""
        loadMessagesIfNeeded(veraThreadID)
        focusTick &+= 1
    }

    private func stashDraft() {
        guard let selectedID else { return }
        if draft.isEmpty { drafts.removeValue(forKey: selectedID) } else { drafts[selectedID] = draft }
    }

    private func loadMessagesIfNeeded(_ id: String) {
        guard let repository,
              let idx = conversations.firstIndex(where: { $0.id == id }),
              conversations[idx].messages.isEmpty else { return }
        do {
            let msgs = try repository.messages(conversationID: id)
            conversations[idx].messages = msgs
        } catch {
            chatConfigurationError = "Messages couldn't load: \(error.localizedDescription)"
        }
    }

    func select(_ id: String) {
        stashDraft()
        section = isVeraThread(id) ? .vera : .chat
        selectedID = id
        if !isVeraThread(id) { lastFocusedConversationID = id }
        draft = drafts[id] ?? ""
        loadMessagesIfNeeded(id)
    }

    func openChats() {
        if let id = lastFocusedConversationID, conversations.contains(where: { $0.id == id }) {
            select(id)
        } else {
            newConversation()
        }
    }

    var selected: Conversation? {
        guard let id = selectedID else { return nil }
        return conversations.first { $0.id == id }
    }

    // MARK: - Memory actions

    func inspectMemoryCitation(_ url: String) {
        guard let id = NativeMemoryCitation.recordID(url), let local = repository as? LocalChatRepository else { return }
        do {
            guard let record = try local.allMemories().first(where: { $0.id == id && $0.status != .deleted }) else {
                throw NativeMemoryEvidenceError.removed
            }
            let revision = NativeMemoryCitation.revision(url)
            if let revision, !(try local.memoryEvidence(id)).contains(where: { $0.revision == revision }) {
                throw NativeMemoryEvidenceError.unavailable
            }
            inspectedMemoryRevision = revision
            inspectedMemoryTrace = selectedID.flatMap { memoryRetrievalTraces[$0] }
            inspectedMemory = record
        } catch {
            memoryServiceState = .failed(error.localizedDescription)
            section = .memory
        }
    }

    func memoryEvidence(_ id: String) throws -> [NativeMemoryEvidence] {
        guard let local = repository as? LocalChatRepository else { throw NativeMemoryEvidenceError.unavailable }
        return try local.memoryEvidence(id)
    }

    func loadMemoryLibrary(now: Date? = nil) {
        reloadNativeMemory(now: now)
    }

    func reloadNativeMemory(now: Date? = nil) {
        guard !reloadingNativeMemory, let memoryRepository = repository as? any NativeMemoryRepository else { return }
        reloadingNativeMemory = true
        defer { reloadingNativeMemory = false }
        var refreshError: Error?
        if nativeMemorySettings.enabled, let local = repository as? LocalChatRepository {
            do { try local.refreshDomainProjections(now: now ?? nativeMemoryNow()) } catch { refreshError = error }
        }
        defer { if let refreshError { memoryServiceState = .retrievalUnavailable(refreshError.localizedDescription) } }
        memoryLibraryRevision += 1
        do {
            memoryRecords = try memoryRepository.allMemories().filter { $0.status != .deleted }
            memoryProposals = try memoryRepository.pendingProposals()
            if !nativeMemorySettings.enabled {
                memoryServiceState = .off
            } else if !memoryProposals.isEmpty {
                memoryServiceState = .pendingReview(memoryProposals.count)
            } else {
                memoryServiceState = .ready
            }
        } catch {
            memoryServiceState = .failed("The local memory library could not open: \(error.localizedDescription)")
        }
    }

    func updateNativeRules(_ rules: NativeRules) {
        nativeRules = rules
        nativeRuleSource.setGlobal(rules)
    }

    func updateNativeMemory(
        settings: NativeMemorySettings, service: (any NativeMemoryServing)?
    ) {
        nativeMemorySettings = settings
        nativeMemoryService = service
        reloadNativeMemory()
        runMemoryGroom()
        runNativeMemoryMaintenance()
        if service == nil { memoryEndpointStatus = .notConfigured }
        indexApprovedMemoryIfNeeded()
    }

    @discardableResult
    func probeMemoryEndpoint() async -> NativeMemoryEndpointStatus {
        guard let service = nativeMemoryService else {
            memoryEndpointStatus = .notConfigured
            return memoryEndpointStatus
        }
        memoryEndpointStatus = .checking
        do {
            let models = try await service.probe()
            memoryEndpointStatus = .connected(models: models.count)
            indexApprovedMemoryIfNeeded()
            await drainQueuedMemoryTurns()
        } catch {
            memoryEndpointStatus = .unreachable(error.localizedDescription)
        }
        return memoryEndpointStatus
    }

    var memoryRecallDescription: String {
        guard nativeMemorySettings.enabled else { return "" }
        guard let service = nativeMemoryService else { return "Recall uses local search only until a memory endpoint is set." }
        if !semanticRecallAvailable(service, settings: nativeMemorySettings) { return "Recall uses local search only until an embeddings model is chosen." }
        switch memoryEndpointStatus {
        case .unreachable: return "The memory endpoint is unreachable, so recall uses local search for now."
        default:
            if let status = memoryVectorStatus, !status.complete { return "Recall uses local search until memory vectors finish preparing." }
            return "Recall combines local search with semantic search through the memory endpoint."
        }
    }

    private func semanticRecallAvailable(_ service: any NativeMemoryServing, settings: NativeMemorySettings) -> Bool {
        !settings.embeddingsModel.trimmingCharacters(in: .whitespaces).isEmpty || service.supportsSemanticRecall
    }

    private func enqueueMemoryTurn(_ turn: NativeMemoryQueuedTurn) {
        queuedMemoryTurns.removeAll { $0.turnKey == turn.turnKey }
        queuedMemoryTurns.append(turn)
        if queuedMemoryTurns.count > Self.queuedMemoryTurnLimit {
            queuedMemoryTurns.removeFirst(queuedMemoryTurns.count - Self.queuedMemoryTurnLimit)
        }
        let count = queuedMemoryTurns.count
        let message = "The memory endpoint could not be reached. \(count) suggestion\(count == 1 ? "" : "s") waiting to be reviewed when it returns."
        memoryQueueStatusMessage = message
        memoryServiceState = .retrievalUnavailable(message)
    }

    func drainQueuedMemoryTurns() async {
        guard !queuedMemoryTurns.isEmpty, nativeMemoryService != nil, !drainingMemoryQueue else { return }
        drainingMemoryQueue = true
        defer { drainingMemoryQueue = false }
        let pending = queuedMemoryTurns
        queuedMemoryTurns = []
        for (offset, turn) in pending.enumerated() {
            guard nativeMemorySettings.enabled, nativeMemorySettings.generateFromChats, nativeMemoryService != nil else {
                for rest in pending[offset...] { enqueueMemoryTurn(rest) }
                return
            }
            guard queuedTurnStillAllowed(turn) else { continue }
            await learnFromCompletedTurn(
                user: turn.user, assistant: turn.assistant, source: turn.source,
                turnKey: turn.turnKey, conversationExcluded: turn.conversationExcluded)
            if queuedMemoryTurns.contains(where: { $0.turnKey == turn.turnKey }) {
                for rest in pending[(offset + 1)...] { enqueueMemoryTurn(rest) }
                return
            }
        }
        if queuedMemoryTurns.isEmpty, case .retrievalUnavailable(let detail) = memoryServiceState, detail == memoryQueueStatusMessage {
            memoryQueueStatusMessage = nil
            reloadNativeMemory()
        }
    }

    private func queuedTurnStillAllowed(_ turn: NativeMemoryQueuedTurn) -> Bool {
        guard let source = turn.source else { return !turn.conversationExcluded }
        guard let conversation = conversations.first(where: { $0.id == source.conversationID }) else { return false }
        return !conversation.memoryExcluded
    }

    func requestMemoryChange(_ request: String) {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let sensitiveHandling = nativeMemorySettings.sensitiveHandling
        guard sensitiveHandling.allows(trimmed) else {
            memoryServiceState = .failed("Memory skipped text that looks like a credential or secret.")
            return
        }
        guard nativeMemorySettings.enabled, !trimmed.isEmpty,
              let service = nativeMemoryService,
              let memoryRepository = repository as? any NativeMemoryRepository else {
            memoryServiceState = nativeMemorySettings.enabled ? .setupRequired : .off
            return
        }
        memoryServiceState = .indexing
        Task {
            do {
                let proposals = try await service.proposal(
                    request: trimmed, sensitiveHandling: sensitiveHandling,
                    existing: { try memoryRepository.extractionMemories() }, now: Date())
                try await saveMemoryProposals(
                    proposals, service: service, repository: memoryRepository,
                    flagged: NativeMemorySensitiveHandling.needsReview(trimmed),
                    allowed: { self.nativeMemorySettings.enabled })
                reloadNativeMemory()
            } catch {
                memoryServiceState = .retrievalUnavailable(error.localizedDescription)
            }
        }
    }

    func scanPastChatsIfAllowed() {
        guard nativeMemorySettings.enabled else {
            memoryServiceState = .off
            return
        }
        guard nativeMemorySettings.searchPastChats else {
            memoryServiceState = .notice("Turn on Search past chats in Settings to scan.")
            return
        }
        searchPastChatsForMemory()
    }

    private var pastChatScanAllowed: Bool {
        nativeMemorySettings.enabled && nativeMemorySettings.searchPastChats
    }

    func searchPastChatsForMemory() {
        guard nativeMemorySettings.enabled, nativeMemorySettings.searchPastChats,
              let service = nativeMemoryService,
              let memoryRepository = repository as? any NativeMemoryRepository else {
            memoryServiceState = nativeMemorySettings.enabled ? .setupRequired : .off
            return
        }
        let candidates = Array(conversations.lazy.filter { !$0.memoryExcluded }.prefix(12))
        memoryServiceState = .indexing
        Task {
            do {
                var reviewedTurns = 0
                var reviewedBytes = 0
                search: for conversation in candidates where reviewedTurns < 12 {
                    let messages = conversation.messages.isEmpty
                        ? try repository?.recentMessages(conversationID: conversation.id, limit: 48) ?? []
                        : Array(conversation.messages.suffix(48))
                    for index in messages.indices where reviewedTurns < 12 {
                        guard pastChatScanAllowed else { break search }
                        let sensitiveHandling = nativeMemorySettings.sensitiveHandling
                        guard messages[index].role == .user,
                              messages.indices.contains(index + 1),
                              messages[index + 1].role == .assistant,
                              NativeMemoryExtractionPolicy.disposition(
                                user: messages[index].text, assistant: messages[index + 1],
                                conversationExcluded: conversation.memoryExcluded,
                                sensitiveHandling: sensitiveHandling) == .eligible else { continue }
                        let turnBytes = NativeMemorySafety.boundedUTF8(
                            messages[index].text, maximumBytes: 4_000).utf8.count
                            + NativeMemorySafety.boundedUTF8(
                                messages[index + 1].text, maximumBytes: 4_000).utf8.count
                        guard reviewedBytes + turnBytes <= 48_000 else { break search }
                        let extraction = try await service.extraction(
                            user: messages[index].text, assistant: messages[index + 1].text,
                            sourceConversationID: conversation.id,
                            sourceMessageID: messages[index].id.uuidString,
                            sensitiveHandling: sensitiveHandling,
                            existing: { try memoryRepository.extractionMemories() }, now: Date())
                        guard pastChatScanAllowed else { break search }
                        let flagged = NativeMemorySensitiveHandling.needsReview(
                            messages[index].text, messages[index + 1].text)
                        try await saveMemoryProposals(
                            extraction.proposals, service: service, repository: memoryRepository,
                            flagged: flagged,
                            sourceText: messages[index].text,
                            allowed: { self.pastChatScanAllowed })
                        stageDomainCandidates(
                            extraction,
                            source: NativeMemoryTurnSource(conversationID: conversation.id,
                                messageID: messages[index].id.uuidString, date: messages[index].createdAt),
                            sourceText: messages[index].text,
                            turnKey: conversation.id + "|" + messages[index].id.uuidString,
                            flagged: flagged, allowed: { self.pastChatScanAllowed })
                        reviewedTurns += 1
                        reviewedBytes += turnBytes
                    }
                }
                reloadNativeMemory()
            } catch {
                memoryServiceState = .retrievalUnavailable(error.localizedDescription)
            }
        }
    }

    func openMemorySource(conversationID: String?) {
        openMemorySource(conversationID: conversationID, messageID: nil)
    }

    func openMemorySource(conversationID: String?, messageID: String?, expectedText: String? = nil) {
        openMemorySource(conversationID: conversationID, messageID: messageID,
                         snapshot: expectedText.map(NativeMemorySourceSnapshot.text) ?? .untracked)
    }

    func openMemorySource(conversationID: String?, messageID: String?, snapshot: NativeMemorySourceSnapshot) {
        guard let conversationID,
              let conversation = conversations.first(where: { $0.id == conversationID }) else {
            memoryServiceState = .failed("The source conversation is no longer available on this Mac.")
            return
        }
        pendingHighlightMessageID = nil
        pendingSourceNotice = nil
        NativePiNativeContext.presentation.isSelected = false
        classicChatRequest += 1
        select(conversationID)
        let loaded = conversations.first(where: { $0.id == conversationID })?.messages ?? []
        let message = messageID.flatMap(UUID.init(uuidString:)).flatMap { id in
            loaded.first(where: { $0.id == id && $0.failure == nil })
        }
        if let message { pendingHighlightMessageID = message.id }
        let state: NativeMemorySourceState
        if conversation.memoryExcluded {
            state = .excluded
        } else if messageID != nil, message == nil {
            state = .deleted
        } else if message != nil, snapshot == .missing {
            state = .edited
        } else if let message, case .text(let text) = snapshot, text != message.text {
            state = .edited
        } else {
            state = .ok
        }
        guard state != .ok else { return }
        pendingSourceNotice = NativeMemorySourceNotice(
            conversationID: conversationID, state: state, message: state.message)
    }

    func dismissSourceNotice() {
        pendingSourceNotice = nil
    }

    func memorySource(_ record: NativeMemoryRecord) -> (conversationID: String?, messageID: String?, snapshot: NativeMemorySourceSnapshot) {
        if let latest = try? memoryEvidence(record.id).max(by: { $0.revision < $1.revision }) {
            return (latest.record.sourceConversationID ?? record.sourceConversationID,
                    latest.record.sourceMessageID ?? record.sourceMessageID,
                    latest.sourceText.map(NativeMemorySourceSnapshot.text) ?? .missing)
        }
        return (record.sourceConversationID, record.sourceMessageID, .missing)
    }

    func openMemorySource(_ record: NativeMemoryRecord) {
        let source = memorySource(record)
        openMemorySource(conversationID: source.conversationID, messageID: source.messageID, snapshot: source.snapshot)
    }

    var currentMemorySettings: NativeMemorySettings { nativeMemorySettings }

    func clearPendingHighlight(_ id: UUID) {
        if pendingHighlightMessageID == id { pendingHighlightMessageID = nil }
    }

    func proposeDomainRecord(_ entry: NativeDomainEntry, label: String) throws {
        guard nativeMemorySettings.enabled, let local = repository as? LocalChatRepository else { throw NativeDomainError.changed }
        _ = try local.stageDomainProposal(entry, label: label)
        reloadNativeMemory()
    }

    private func boundConsent(_ record: NativeMemoryRecord, grant: Bool) throws -> NativeMemoryRecord {
        var result = record
        var current: String?
        if let conversation = record.sourceConversationID, let message = record.sourceMessageID {
            guard let local = repository as? LocalChatRepository else { throw NativeMemoryEvidenceError.unavailable }
            current = try local.memorySourceVersion(conversationID: conversation, messageID: message)
            if grant, current == nil { throw NativeMemorySourceConsentError.sourceChanged }
        }
        if grant {
            result.sensitiveConsent = true
            result.sensitiveConsentVersion = current
        } else if result.sensitiveConsent == true, result.sourceMessageID != nil,
                  current == nil || current != result.sensitiveConsentVersion {
            result.sensitiveConsent = nil
            result.sensitiveConsentVersion = nil
        }
        return result
    }

    @discardableResult
    func acceptMemoryProposal(_ proposal: NativeMemoryProposal, editedDetails: [String]? = nil) -> Bool {
        guard let memoryRepository = repository as? any NativeMemoryRepository else { return false }
        do {
            if proposal.domain != nil {
                guard editedDetails == nil, let local = repository as? LocalChatRepository else { throw NativeDomainError.invalid }
                try local.approveDomainProposal(proposal)
                memoryLibraryRevision += 1
                reloadNativeMemory()
                indexApprovedMemoryIfNeeded()
                return true
            }
            let sensitive = proposal.sensitiveReview == true
            if sensitive, nativeMemorySettings.sensitiveHandling != .reviewOnly {
                memoryServiceState = .failed("This suggestion contains sensitive text. Set Sensitive information to Suggest for review only in Settings to accept it.")
                return false
            }
            if let conversation = proposal.sourceConversationID, let message = proposal.sourceMessageID,
               sensitive || proposal.sourceVersion != nil {
                if conversations.first(where: { $0.id == conversation })?.memoryExcluded == true {
                    memoryServiceState = .failed("This conversation is excluded from memory suggestions.")
                    return false
                }
                let current = (repository as? LocalChatRepository).flatMap {
                    try? $0.memorySourceVersion(conversationID: conversation, messageID: message)
                }
                guard let expected = proposal.sourceVersion, current == expected else {
                    memoryServiceState = .failed("The source message changed since this was suggested. Review it again.")
                    return false
                }
            }
            switch proposal.kind {
            case .create:
                var memory = NativeMemoryRecord(
                    id: UUID().uuidString, title: proposal.title,
                    summary: NativeMemorySensitiveHandling.unflagged(proposal.summary),
                    details: editedDetails ?? proposal.details, group: proposal.group,
                    category: proposal.category, bank: proposal.bank,
                    durability: proposal.durability, expiry: proposal.expiry, status: .approved,
                    embedding: nil, sourceConversationID: proposal.sourceConversationID,
                    sourceMessageID: proposal.sourceMessageID, createdAt: Date(), updatedAt: Date())
                memory = try boundConsent(memory, grant: sensitive)
                try memoryRepository.saveMemory(
                    memory, decision: editedDetails == nil ? .accepted : .edited,
                    note: "Approved memory proposal")
            case .update, .merge, .consolidate:
                guard var target = memoryRecords.first(where: { proposal.targetIDs.contains($0.id) }) else { return false }
                let expected = target
                target.title = proposal.title
                target.summary = NativeMemorySensitiveHandling.unflagged(proposal.summary)
                target.details = editedDetails ?? proposal.details
                target.group = proposal.group
                target.category = proposal.category
                target.bank = proposal.bank
                target.durability = proposal.durability
                target.expiry = proposal.expiry
                target.embedding = nil
                if let source = proposal.sourceConversationID, let message = proposal.sourceMessageID {
                    target.sourceConversationID = source
                    target.sourceMessageID = message
                }
                target = try boundConsent(target, grant: sensitive)
                target.updatedAt = Date()
                try memoryRepository.saveMemory(
                    target, decision: proposal.kind == .update ? .edited : .merged,
                    note: "Approved memory proposal", expected: expected)
                if proposal.kind == .merge || proposal.kind == .consolidate {
                    for id in proposal.targetIDs where id != target.id { try memoryRepository.deleteMemory(id) }
                }
            case .suppress:
                guard var target = memoryRecords.first(where: { proposal.targetIDs.contains($0.id) }) else { return false }
                let expected = target
                target.status = .suppressed
                target.embedding = nil
                target.updatedAt = Date()
                try memoryRepository.saveMemory(target, decision: .suppressed, note: "Approved suppression", expected: expected)
            case .expire, .delete, .cleanup:
                for id in proposal.targetIDs { try memoryRepository.deleteMemory(id) }
            }
            try memoryRepository.decideProposal(proposal.id, status: .accepted)
            reloadNativeMemory()
            indexApprovedMemoryIfNeeded()
            return true
        } catch {
            memoryServiceState = .failed("The proposal could not be applied: \(error.localizedDescription)")
            return false
        }
    }

    func dismissMemoryProposal(_ proposal: NativeMemoryProposal) {
        guard let memoryRepository = repository as? any NativeMemoryRepository else { return }
        do {
            try memoryRepository.decideProposal(proposal.id, status: .dismissed)
            reloadNativeMemory()
        } catch {
            memoryServiceState = .failed("The proposal could not be dismissed: \(error.localizedDescription)")
        }
    }

    func deleteNativeMemory(_ memory: NativeMemoryRecord) {
        guard let memoryRepository = repository as? any NativeMemoryRepository else { return }
        do {
            try memoryRepository.deleteMemory(memory.id)
            reloadNativeMemory()
        } catch {
            memoryServiceState = .failed("The memory could not be deleted: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func editNativeMemory(
        _ memory: NativeMemoryRecord, title: String, summary: String, details: [String]
    ) -> Bool {
        guard let memoryRepository = repository as? any NativeMemoryRepository else { return false }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDetails = details.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleanTitle.isEmpty, cleanTitle.count <= 80,
              !cleanSummary.isEmpty, cleanSummary.count <= 180,
              !cleanDetails.isEmpty, cleanDetails.count <= 8,
              cleanDetails.allSatisfy({ $0.count <= 600 }) else {
            memoryServiceState = .failed("Keep the name, summary, and details concise before saving.")
            return false
        }
        do {
            var updated = memory
            updated.title = cleanTitle
            updated.summary = cleanSummary
            updated.details = cleanDetails
            updated.embedding = nil
            updated.updatedAt = Date()
            updated = try boundConsent(updated, grant: false)
            try memoryRepository.saveMemory(updated, decision: .edited, note: "Edited by the user", expected: memory)
            reloadNativeMemory()
            indexApprovedMemoryIfNeeded()
            return true
        } catch {
            memoryServiceState = .failed("The memory could not be saved: \(error.localizedDescription)")
            return false
        }
    }

    func clearNativeMemory() {
        guard let memoryRepository = repository as? any NativeMemoryRepository else { return }
        do {
            for memory in try memoryRepository.approvedMemories() {
                try memoryRepository.deleteMemory(memory.id)
            }
            if let local = repository as? LocalChatRepository { try local.revokeUnprojectedDomainStreams() }
            memoryLibraryRevision += 1
            reloadNativeMemory()
        } catch {
            memoryServiceState = .failed("The memory library could not be cleared: \(error.localizedDescription)")
        }
    }

    var memoryGroomOutcomeDisplaySeconds: Double = 900
    @discardableResult
    func runMemoryGroom(
        dryRun: Bool = false, now: Date = Date(), calendar: Calendar = .current
    ) -> NativeMemoryGroomOutcome? {
        guard nativeMemorySettings.enabled,
              let memoryRepository = repository as? any NativeMemoryRepository else { return nil }
        do {
            let records = try memoryRepository.allMemories()
            let expired = NativeMemoryGroom.expired(records: records, now: now, calendar: calendar)
            if dryRun {
                let outcome = NativeMemoryGroomOutcome(
                    removedIDs: expired.map(\.id), invalidatedProposalCount: 0,
                    dryRun: true, error: nil, finishedAt: now)
                memoryGroomOutcome = outcome
                scheduleMemoryGroomOutcomeClear(outcome)
                return outcome
            }
            let liveIDs = Set(records.filter { $0.status != .deleted }.map(\.id))
                .subtracting(expired.map(\.id))
            let dangling = NativeMemoryGroom.danglingProposals(
                pending: try memoryRepository.pendingProposals(), liveRecordIDs: liveIDs)
            guard !expired.isEmpty || !dangling.isEmpty else {
                memoryGroomOutcome = nil
                return nil
            }
            var removedIDs: [String] = []
            for record in expired {
                try memoryRepository.deleteMemory(record.id, note: "Removed by the expiry groom")
                removedIDs.append(record.id)
            }
            for proposal in dangling {
                try memoryRepository.decideProposal(
                    proposal.id, status: .dismissed,
                    note: "Invalidated by the expiry groom: the target memory is gone",
                    memoryID: NativeMemoryGroom.missingTarget(of: proposal, liveRecordIDs: liveIDs))
            }
            let outcome = NativeMemoryGroomOutcome(
                removedIDs: removedIDs, invalidatedProposalCount: dangling.count,
                dryRun: false, error: nil, finishedAt: now)
            memoryGroomOutcome = outcome
            scheduleMemoryGroomOutcomeClear(outcome)
            reloadNativeMemory()
            return outcome
        } catch {
            let outcome = NativeMemoryGroomOutcome(
                removedIDs: [], invalidatedProposalCount: 0, dryRun: dryRun,
                error: error.localizedDescription, finishedAt: now)
            memoryGroomOutcome = outcome
            return outcome
        }
    }

    private func scheduleMemoryGroomOutcomeClear(_ outcome: NativeMemoryGroomOutcome) {
        let delay = UInt64(max(0, memoryGroomOutcomeDisplaySeconds) * 1_000_000_000)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, self.memoryGroomOutcome == outcome else { return }
            self.memoryGroomOutcome = nil
        }
    }

    private var memoryGroomLoopStarted = false
    private func startMemoryGroomLoop() {
        guard !memoryGroomLoopStarted else { return }
        memoryGroomLoopStarted = true
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 24 * 60 * 60 * 1_000_000_000)
                guard let self else { return }
                self.runMemoryGroom()
                self.runNativeMemoryMaintenance()
            }
        }
    }

    private func runNativeMemoryMaintenance() {
        guard nativeMemorySettings.enabled,
              let memoryRepository = repository as? any NativeMemoryRepository else { return }
        do {
            let records = try memoryRepository.allMemories()
            let pending = try memoryRepository.pendingProposals()
            for proposal in NativeMemoryMaintenance.proposals(records: records, existing: pending) {
                try memoryRepository.saveProposal(proposal)
            }
            reloadNativeMemory()
        } catch {
            memoryServiceState = .failed("Memory maintenance could not finish: \(error.localizedDescription)")
        }
    }

    func indexApprovedMemoryIfNeeded() {
        guard nativeMemorySettings.enabled, let service = nativeMemoryService, semanticRecallAvailable(service, settings: nativeMemorySettings) else {
            refreshMemoryVectorStatus()
            return
        }
        backfillMemoryVectorsIfNeeded()
    }

    func learnFromCompletedTurn(
        user: String, assistant: Message, source: NativeMemoryTurnSource?, turnKey: String, conversationExcluded: Bool
    ) async {
        let live = nativeMemorySettings
        guard live.enabled, live.generateFromChats,
              let memoryService = nativeMemoryService,
              let memoryRepository = repository as? any NativeMemoryRepository,
              NativeMemoryExtractionPolicy.disposition(
                user: user, assistant: assistant, conversationExcluded: conversationExcluded,
                sensitiveHandling: live.sensitiveHandling) == .eligible else { return }
        let allowed = { self.nativeMemorySettings.enabled && self.nativeMemorySettings.generateFromChats }
        do {
            let extraction = try await memoryService.extraction(
                user: user, assistant: assistant.text,
                sourceConversationID: source?.conversationID, sourceMessageID: source?.messageID,
                sensitiveHandling: live.sensitiveHandling,
                existing: { try memoryRepository.extractionMemories() }, now: Date())
            let flagged = NativeMemorySensitiveHandling.needsReview(user, assistant.text)
            try await saveMemoryProposals(
                extraction.proposals, service: memoryService, repository: memoryRepository,
                flagged: flagged, sourceText: source == nil ? nil : user, allowed: allowed)
            stageDomainCandidates(extraction, source: source, sourceText: user, turnKey: turnKey,
                                  flagged: flagged, allowed: allowed)
            reloadNativeMemory()
        } catch let error as NativeMemoryServiceError where error.isEndpointOutage {
            memoryEndpointStatus = .unreachable(error.localizedDescription)
            enqueueMemoryTurn(NativeMemoryQueuedTurn(
                user: user, assistant: assistant, source: source, turnKey: turnKey,
                conversationExcluded: conversationExcluded))
        } catch {
            memoryServiceState = .retrievalUnavailable(error.localizedDescription)
        }
    }

    private func stageDomainCandidates(
        _ extraction: NativeMemoryExtraction, source: NativeMemoryTurnSource?, sourceText: String,
        turnKey: String, flagged: Bool, allowed: () -> Bool
    ) {
        guard let local = repository as? LocalChatRepository, !flagged else { return }
        func skip(_ reason: String, _ index: Int) {
            try? local.recordDomainExtractionSkip(reason, key: turnKey + "|" + String(index))
        }
        for (index, reason) in extraction.skippedDomainEntries.enumerated() {
            guard nativeMemorySettings.enabled, allowed() else { return }
            skip(reason, -1 - index)
        }
        for (index, candidate) in extraction.domainEntries.prefix(NativeDomainCandidateParser.limit).enumerated() {
            guard nativeMemorySettings.enabled, allowed() else { return }
            guard let source else {
                skip("source is not saved on this Mac", index)
                continue
            }
            do {
                _ = try local.stageExtractedDomainEntry(
                    candidate, conversationID: source.conversationID, messageID: source.messageID,
                    sourceText: sourceText, fallbackDate: source.date)
            } catch let error as NativeDomainExtractionSkip {
                skip(error.reason, index)
            } catch {
                skip("the entry could not be staged", index)
            }
        }
    }

    private func saveMemoryProposals(
        _ proposals: [NativeMemoryProposal], service: any NativeMemoryServing,
        repository: any NativeMemoryRepository, flagged: Bool = false, sourceText: String? = nil,
        allowed: () -> Bool
    ) async throws {
        guard nativeMemorySettings.enabled, allowed() else { return }
        let existing = try repository.approvedMemories()
        let pending = try repository.pendingProposals().filter { $0.domain == nil && $0.sourceMessageID != nil }
        for proposal in proposals where NativeMemorySafety.proposalIsSafe(proposal) {
            guard nativeMemorySettings.enabled, allowed() else { return }
            var reconciled = proposal
            if proposal.kind == .create,
               existing.contains(where: { $0.embedding != nil }),
               let embedding = try? await service.embed(proposal.details.joined(separator: "\n")) {
                guard nativeMemorySettings.enabled, allowed() else { return }
                reconciled = NativeMemoryReconciliation.reconcile(
                    proposal, candidateEmbedding: embedding, existing: existing)
            }
            if flagged { reconciled = NativeMemorySensitiveHandling.flagged(reconciled) }
            if reconciled.sourceMessageID != nil, let sourceText {
                reconciled.sourceVersion = LocalChatRepository.memorySourceVersion(sourceText)
            }
            guard nativeMemorySettings.enabled, allowed() else { return }
            if reconciled.sourceMessageID != nil, let match = pending.first(where: {
                $0.kind == reconciled.kind && $0.title == reconciled.title && $0.summary == reconciled.summary
                    && $0.details == reconciled.details && $0.group == reconciled.group && $0.category == reconciled.category
                    && $0.bank == reconciled.bank && $0.durability == reconciled.durability && $0.expiry == reconciled.expiry
                    && $0.targetIDs == reconciled.targetIDs && $0.sensitiveReview == reconciled.sensitiveReview
                    && $0.sourceConversationID == reconciled.sourceConversationID && $0.sourceMessageID == reconciled.sourceMessageID
            }) {
                if match.sourceVersion == reconciled.sourceVersion { continue }
                reconciled.id = match.id
                reconciled.createdAt = match.createdAt
                guard let local = repository as? LocalChatRepository else { continue }
                _ = try local.refreshPendingProposal(reconciled, replacing: match.sourceVersion)
                continue
            }
            try repository.saveProposal(reconciled)
        }
    }

    func newConversation() {
        stashDraft()
        section = .chat
        if let existing = conversations.first(where: { $0.title == "New chat" && $0.messages.isEmpty && !isVeraThread($0.id) }) {
            selectedID = existing.id
            draft = drafts[existing.id] ?? ""
        } else {
            let convo = Conversation(id: UUID().uuidString, title: "New chat", messages: [], updatedAt: Date())
            conversations.insert(convo, at: 0)
            selectedID = convo.id
            draft = ""
        }
        lastFocusedConversationID = selectedID
        focusTick &+= 1
    }

    func togglePin(_ id: String) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].pinned.toggle()
        conversations[i].updatedAt = Date()
        do { try repository?.saveConversation(conversations[i]) }
        catch { chatConfigurationError = "Pin state couldn't save: \(error.localizedDescription)" }
    }

    func renameConversation(_ id: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].title = trimmed
        conversations[i].titleSource = .user
        do { try repository?.saveConversation(conversations[i]) }
        catch { chatConfigurationError = "The new name couldn't save: \(error.localizedDescription)" }
    }

    func generateTitleIfNeeded(conversationID: String) {
        guard generatesConversationTitles, !titleGenerationInFlight.contains(conversationID),
              !titleGenerationAttempted.contains(conversationID),
              let conversation = conversations.first(where: { $0.id == conversationID }),
              ConversationTitleGenerator.shouldGenerate(for: conversation, isAssistantThread: isVeraThread(conversationID)),
              let transport = nativeTransport, let model = nativeConfig?.model, !model.isEmpty,
              let user = conversation.messages.first(where: { $0.role == .user }),
              let reply = conversation.messages.first(where: { $0.role == .assistant }) else { return }
        titleGenerationInFlight.insert(conversationID)
        titleGenerationAttempted.insert(conversationID)
        let userID = user.id
        let timeout = titleGenerationTimeout
        Task {
            let title = await ConversationTitleGenerator.generate(
                transport: transport, model: model, user: user.text, assistant: reply.text, timeout: timeout)
            self.titleGenerationInFlight.remove(conversationID)
            guard let title,
                  let i = self.conversations.firstIndex(where: { $0.id == conversationID }),
                  self.conversations[i].titleSource == .fallback,
                  self.conversations[i].messages.first(where: { $0.role == .user })?.id == userID else { return }
            self.conversations[i].title = title
            self.conversations[i].titleSource = .generated
            try? self.repository?.saveConversation(self.conversations[i])
        }
    }

    func toggleMemoryExclusion(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].memoryExcluded.toggle()
        conversations[index].updatedAt = Date()
        do { try repository?.saveConversation(conversations[index]) }
        catch { chatConfigurationError = "The conversation memory setting could not save: \(error.localizedDescription)" }
        reloadNativeMemory()
    }

    var promptLibrary: (any NativePromptLibraryRepository)? {
        repository as? any NativePromptLibraryRepository
    }

    var activePersonaID: String? { nativePersonaID }

    struct ResolvedPromptScopes: Equatable {
        var persona: String
        var userScope: String
        var instructions: String
    }

    func resolvePromptScopes(conversationID: String?) -> ResolvedPromptScopes {
        var persona = nativeSystemPrompt
        var userScope = ""
        if let library = promptLibrary, let profiles = try? library.promptProfiles() {
            if let id = nativePersonaID,
               let active = profiles.first(where: { $0.id == id && $0.scope == .persona }) {
                persona = active.content
            } else if let first = profiles.first(where: { $0.scope == .persona }) {
                persona = first.content
            }
            userScope = profiles.filter { $0.scope == .user }
                .map(\.content).joined(separator: "\n\n")
        }
        let instructions = conversationID
            .flatMap { id in conversations.first(where: { $0.id == id })?.instructions } ?? ""
        return ResolvedPromptScopes(persona: persona, userScope: userScope, instructions: instructions)
    }

    func setConversationInstructions(_ id: String, _ text: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try NativePromptValidation.validateInstructions(trimmed)
        } catch {
            chatConfigurationError = error.localizedDescription
            return
        }
        conversations[index].instructions = trimmed.isEmpty ? nil : trimmed
        conversations[index].updatedAt = Date()
        do { try repository?.saveConversation(conversations[index]) }
        catch { chatConfigurationError = "The conversation instructions could not save: \(error.localizedDescription)" }
    }

    func setConversationGrounding(_ id: String, _ collectionIDs: [String]) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].grounding = collectionIDs
        conversations[index].updatedAt = Date()
        do { try repository?.saveConversation(conversations[index]) }
        catch { chatConfigurationError = "The grounding selection could not save: \(error.localizedDescription)" }
    }

    func adoptPersona(_ id: String?) {
        nativePersonaID = id
    }

    // id must be STABLE across renders (title is) — a fresh UUID each compute breaks SwiftUI's
    // LazyVStack identity and leaks the selected-row background onto a recycled slot.
    struct SidebarGroup: Identifiable { var id: String { title }; let title: String; let convos: [Conversation] }

    /// Conversations grouped for the sidebar: Pinned, then Recents bucketed by recency.
    func sidebarGroups(search: String) -> [SidebarGroup] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seenIDs = Set<String>()
        let visible = conversations.filter {
            guard seenIDs.insert($0.id).inserted else { return false }
            guard $0.id != veraThreadID else { return false }
            return (!$0.messages.isEmpty || $0.isPersisted) && (q.isEmpty || $0.title.lowercased().contains(q))
        }
        let pinned = visible.filter { $0.pinned }.sorted { $0.updatedAt > $1.updatedAt }
        let rest = visible.filter { !$0.pinned }.sorted { $0.updatedAt > $1.updatedAt }
        var groups: [SidebarGroup] = []
        if !pinned.isEmpty { groups.append(.init(title: "Pinned", convos: pinned)) }
        let cal = Calendar.current, now = Date()
        func bucket(_ d: Date) -> String {
            if cal.isDateInToday(d) { return "Today" }
            if cal.isDateInYesterday(d) { return "Yesterday" }
            let days = cal.dateComponents([.day], from: d, to: now).day ?? 0
            return days < 7 ? "Previous 7 days" : (days < 30 ? "Previous 30 days" : "Older")
        }
        var byBucket: [String: [Conversation]] = [:]
        for c in rest { byBucket[bucket(c.updatedAt), default: []].append(c) }
        for b in ["Today", "Yesterday", "Previous 7 days", "Previous 30 days", "Older"] {
            if let cs = byBucket[b], !cs.isEmpty { groups.append(.init(title: b, convos: cs)) }
        }
        return groups
    }

    func deleteConversation(_ id: String) {
        guard !isVeraThread(id) else { return }
        suspendsTurnScheduling = true
        defer { suspendsTurnScheduling = false; scheduleConversationTurns() }
        for turn in conversationTurns where turn.conversationID == id {
            stopAnswer(turn.assistantMessageID)
        }
        let idx = conversations.firstIndex { $0.id == id }
        let stored = (try? repository?.messages(conversationID: id)) ?? []
        conversations.removeAll { $0.id == id }
        drafts.removeValue(forKey: id)
        if lastFocusedConversationID == id { lastFocusedConversationID = nil }
        if selectedID == id {
            let candidates = conversations.filter { !isVeraThread($0.id) }
            let next = idx.flatMap { candidates.indices.contains($0) ? candidates[$0] : candidates.last }
            selectedID = nil
            draft = ""
            if let next { select(next.id) }
        }
        do {
            try repository?.deleteConversation(id)
            for message in stored {
                for attachment in message.attachments { attachmentStore.remove(attachment) }
            }
        } catch {
            chatConfigurationError = "The conversation couldn't be deleted: \(error.localizedDescription)"
        }
        reloadNativeMemory()
        if selectedID == nil { newConversation() }
    }

    enum PulseContinuationState: Equatable {
        case opening
        case failed(String)
    }

    static let pulseContinuationDatabaseFailure = "Vera couldn't create the local conversation. Try again."

    func openPulseInChat(_ card: PulseCard, onOpened: (() -> Void)? = nil) {
        if pulseContinuation[card.id] == .opening { return }
        guard let repository else {
            pulseContinuation[card.id] = .failed(Self.pulseContinuationDatabaseFailure)
            return
        }
        do {
            if let existing = try repository.conversation(originType: PulseSeed.originType, originID: card.id) {
                pulseContinuation[card.id] = nil
                openContinuation(existing, onOpened: onOpened)
                return
            }
        } catch {
            pulseContinuation[card.id] = .failed(Self.pulseContinuationDatabaseFailure)
            return
        }
        guard let provider = pulseFeedProvider ?? (client as (any PulseFeedProviding)?) else {
            pulseContinuation[card.id] = .failed("Pulse isn't connected. Set up Vera API to continue this card.")
            return
        }
        pulseContinuation[card.id] = .opening
        Task {
            let result = await provider.pulseFeed()
            finishContinuation(card: card, result: result, repository: repository, onOpened: onOpened)
        }
    }

    private func finishContinuation(
        card: PulseCard, result: PulseFeedResult, repository: any ChatRepository,
        onOpened: (() -> Void)?
    ) {
        switch result {
        case .unconfigured:
            pulseContinuation[card.id] = .failed("Pulse isn't connected. Set up Vera API to continue this card.")
        case .transport:
            pulseContinuation[card.id] = .failed("Pulse couldn't be reached. Try again.")
        case .malformed:
            pulseContinuation[card.id] = .failed("This Pulse card couldn't be opened.")
        case .success(let cards, let rawIDs):
            guard let fresh = cards.first(where: { $0.id == card.id }) else {
                pulseContinuation[card.id] = .failed(rawIDs.contains(card.id)
                    ? "This Pulse card couldn't be opened."
                    : "This Pulse card is no longer available.")
                return
            }
            let now = Date()
            let seed = PulseSeed.message(for: fresh, at: now)
            let conversation = Conversation(
                id: UUID().uuidString, title: fresh.title, messages: [seed],
                createdAt: now, updatedAt: now, isPersisted: true,
                originType: PulseSeed.originType, originID: fresh.id)
            do {
                try repository.createOriginConversation(conversation, seed: seed)
            } catch {
                if let existing = try? repository.conversation(
                    originType: PulseSeed.originType, originID: card.id) {
                    pulseContinuation[card.id] = nil
                    openContinuation(existing, onOpened: onOpened)
                } else {
                    pulseContinuation[card.id] = .failed(Self.pulseContinuationDatabaseFailure)
                }
                return
            }
            pulseContinuation[card.id] = nil
            conversations.insert(conversation, at: 0)
            pulseDetail = nil
            onOpened?()
            select(conversation.id)
            focusTick &+= 1
        }
    }

    private func openContinuation(_ conversation: Conversation, onOpened: (() -> Void)?) {
        if !conversations.contains(where: { $0.id == conversation.id }) {
            conversations.insert(conversation, at: 0)
        }
        pulseDetail = nil
        onOpened?()
        select(conversation.id)
        focusTick &+= 1
    }

    // MARK: - Voice mode

    /// Start a voice turn: ensure a conversation exists, append the user's transcript + an empty
    /// assistant placeholder, and return the chat id plus API message history (excluding the
    /// placeholder). `VoiceSession` streams the reply itself (to feed TTS) and calls
    /// `updateVoiceReply` as tokens arrive.
    func beginVoiceTurn(userText: String) -> (chatID: String, messages: [[String: Any]])? {
        section = .chat
        if selectedID == nil || conversations.firstIndex(where: { $0.id == selectedID }) == nil {
            let convo = Conversation(id: UUID().uuidString, title: "New chat", messages: [], updatedAt: Date())
            conversations.insert(convo, at: 0)
            selectedID = convo.id
        }
        guard let id = selectedID, let idx = conversations.firstIndex(where: { $0.id == id }) else { return nil }
        conversations[idx].messages.append(.init(role: .user, text: userText))
        if conversations[idx].title == "New chat" && conversations[idx].titleSource == .fallback {
            conversations[idx].title = String(userText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        }
        conversations[idx].updatedAt = Date()
        let history: [[String: Any]] = conversations[idx].messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        conversations[idx].messages.append(.init(role: .assistant, text: ""))
        return (id, history)
    }

    /// Live-update the streaming assistant reply for a voice turn (the trailing assistant message).
    func updateVoiceReply(chatID: String, text: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == chatID }),
              let last = conversations[idx].messages.indices.last,
              conversations[idx].messages[last].role == .assistant else { return }
        conversations[idx].messages[last].text = text
    }

    // MARK: - Attachments (composer)

    func addFiles(_ urls: [URL]) {
        attachmentError = nil
        for url in urls {
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
                grantFolder(url)
                continue
            }
            do {
                let record = try attachmentStore.save(url: url)
                attachments.append(pendingAttachment(for: record, sourceURL: url))
            } catch {
                attachmentError = error.localizedDescription
            }
        }
    }

    func addPastedImages(_ images: [Data]) {
        attachmentError = nil
        for data in images {
            do {
                let record = try attachmentStore.save(data: data, preferredName: "Pasted image")
                attachments.append(pendingAttachment(for: record, sourceURL: nil))
            } catch {
                attachmentError = error.localizedDescription
            }
        }
    }

    private func pendingAttachment(for record: MessageAttachment, sourceURL: URL?) -> Attachment {
        let fileURL = record.fileName.flatMap { attachmentStore.url(for: $0) }
        let att = Attachment(url: sourceURL ?? fileURL ?? URL(fileURLWithPath: record.name))
        att.nativeRecord = record
        if let fileURL, let image = NSImage(contentsOf: fileURL) {
            att.thumbnail = ImageEncoder.downscale(image, maxDim: 96)
        }
        att.status = .ready
        return att
    }

    func removeAttachment(_ id: UUID) {
        attachmentError = nil
        for att in attachments where att.id == id {
            if let record = att.nativeRecord { attachmentStore.remove(record) }
        }
        attachments.removeAll { $0.id == id }
    }

    struct PendingSendDecision: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let modelID: String
        let imageCount: Int
        let imageLimit: Int?
    }

    struct BridgeTurnFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct NativeParameterRejectionPrompt: Identifiable, Equatable {
        let rejection: ModelParameterRejection
        let model: String
        let detail: String
        let conversationID: String
        var id: String { conversationID + "|" + rejection.key }
    }

    var activeCapabilityResolution: ModelCapabilityCatalog.Resolution? {
        guard let nativeConfig else { return nil }
        return ModelCapabilityCatalog.resolve(
            model: nativeConfig.model, overrides: nativeCapabilityOverrides)
    }

    var effectiveBridgeConfig: VisionBridgeConfig? {
        guard let bridge = visionBridgeConfig else { return nil }
        if let nativeConfig, bridge.isSameEndpoint(as: nativeConfig) {
            return nil
        }
        return bridge
    }

    func attachmentRoute(imageCount: Int) -> AttachmentRoute? {
        guard imageCount > 0 else { return nil }
        guard let resolution = activeCapabilityResolution else { return nil }
        return AttachmentPreflight.route(
            profile: resolution.profile, imageCount: imageCount,
            bridgeConfigured: effectiveBridgeConfig != nil)
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let atts = attachments
        guard !text.isEmpty || !atts.isEmpty else { return }
        guard repository != nil else {
            chatConfigurationError = repositoryInitializationError ?? "Local history couldn't open"
            return
        }
        let imageCount = atts.filter { $0.nativeRecord?.isImage == true }.count
        let route = attachmentRoute(imageCount: imageCount)
        if route == .needsDecision, let model = nativeConfig?.model {
            let profile = activeCapabilityResolution?.profile
            pendingSendDecision = PendingSendDecision(
                text: text, modelID: model, imageCount: imageCount,
                imageLimit: profile?.acceptsImages == true
                    ? max(profile?.maxImagesPerRequest ?? 1, 1) : nil)
            return
        }
        let note: MessageRouteNote?
        switch route {
        case .direct: note = MessageRouteNote(route: .direct)
        case .bridged: note = MessageRouteNote(route: .bridged, bridgeModel: effectiveBridgeConfig?.model)
        default: note = nil
        }
        if sendText(text, attachments: atts, routeNote: note) {
            draft = ""
            attachments = []
        }
    }

    func confirmSendWithoutAttachments() {
        guard pendingSendDecision != nil else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let atts = attachments
        pendingSendDecision = nil
        guard !text.isEmpty else {
            attachmentError = "There is no message text to send without the attachment. Add text or remove the attachment."
            return
        }
        if sendText(text, attachments: atts, routeNote: MessageRouteNote(route: .withheld)) {
            draft = ""
            attachments = []
        }
    }

    func cancelPendingSend() {
        pendingSendDecision = nil
    }

    /// Record the user's answer to a Vera structured question and send it as their next turn.
    func submitAsk(messageID: UUID, selections: [String], other: String) {
        guard repository != nil else {
            chatConfigurationError = repositoryInitializationError ?? "Local history couldn't open"
            return
        }
        guard let id = selectedID,
              let ci = conversations.firstIndex(where: { $0.id == id }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID }) else { return }
        var parts = selections
        let o = other.trimmingCharacters(in: .whitespacesAndNewlines)
        if !o.isEmpty { parts.append(o) }
        let answer = parts.joined(separator: ", ")
        guard !answer.isEmpty else { return }
        if sendText(answer) {
            conversations[ci].messages[mi].answered = true
            conversations[ci].messages[mi].answerText = answer
        }
    }

    @discardableResult
    func sendText(
        _ text: String, attachments atts: [Attachment] = [], routeNote: MessageRouteNote? = nil
    ) -> Bool {
        guard let turnRepository, let repository else {
            chatConfigurationError = repositoryInitializationError ?? "Local history couldn't open"
            return false
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !atts.isEmpty,
              let id = selectedID, let index = conversations.firstIndex(where: { $0.id == id }) else { return false }
        let user = Message(role: .user, text: text, attachments: atts.compactMap(\.nativeRecord), routeNote: routeNote)
        let reply = Message(role: .assistant, text: "", state: .streaming, modelID: nativeConfig?.model)
        var conversation = conversations[index]
        if conversation.title == "New chat" && conversation.titleSource == .fallback {
            conversation.title = text.isEmpty ? (user.attachments.first?.name ?? "New chat") : String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        }
        conversation.updatedAt = Date()
        conversation.isPersisted = true
        let scopes = resolvePromptScopes(conversationID: id)
        let turn = NativeConversationTurn(id: UUID(), conversationID: id,
            userMessageID: user.id, assistantMessageID: reply.id, mode: .chat,
            profile: turnProfile(for: user.routeNote), enabledToolIDs: turnToolIDs(for: text),
            persona: scopes.persona, userScope: scopes.userScope, instructions: scopes.instructions,
            grounding: conversation.grounding, memorySettings: nativeMemorySettings, createdAt: Date(),
            history: NativeTurnHistoryMessage.snapshot(conversation.messages, current: user, mode: .chat))
        do {
            try turnRepository.acceptTurn(turn, conversation: conversation, user: user, reply: reply)
            let stored = (try? repository.messages(conversationID: id)) ?? (conversation.messages + [user, reply])
            let live = Dictionary(uniqueKeysWithValues: conversation.messages.map { ($0.id, $0) })
            conversation.messages = stored.map { live[$0.id] ?? $0 }
            conversations[index] = conversation
            chatConfigurationError = nil
        } catch {
            chatConfigurationError = "The message couldn't save: \(error.localizedDescription)"
            return false
        }
        scheduleConversationTurns()
        return true
    }

    func enrollLegacyAnswer(_ messageID: UUID) -> Bool {
        guard let ci = conversations.firstIndex(where: { $0.messages.contains(where: { $0.id == messageID }) }),
              let ri = conversations[ci].messages.firstIndex(where: { $0.id == messageID }), ri > 0,
              conversations[ci].messages[ri - 1].role == .user,
              conversations[ci].messages[ri].state == .interrupted else { return false }
        let conversation = conversations[ci]
        let user = conversation.messages[ri - 1]
        let reply = conversation.messages[ri]
        guard reply.toolActivities.allSatisfy({ NativeTurnSafety.canReplay($0) }) else {
            chatConfigurationError = "Check whether the earlier action completed, then send a new message."
            return false
        }
        let scopes = resolvePromptScopes(conversationID: conversation.id)
        let turn = NativeConversationTurn(id: UUID(), conversationID: conversation.id,
            userMessageID: user.id, assistantMessageID: reply.id, mode: conversation.mode,
            profile: turnProfile(for: user.routeNote), enabledToolIDs: nativeEnabledToolIDs.intersection(NativeTurnSafety.replayableIDs),
            persona: scopes.persona, userScope: scopes.userScope, instructions: scopes.instructions,
            grounding: conversation.grounding, memorySettings: nativeMemorySettings, createdAt: Date(),
            history: NativeTurnHistoryMessage.snapshot(Array(conversation.messages.prefix(ri - 1)), current: user))
        do {
            try turnRepository?.enrollLegacyTurn(turn)
            conversations[ci].messages[ri].state = .streaming
            conversations[ci].messages[ri].failure = nil
            scheduleConversationTurns()
            return true
        } catch {
            chatConfigurationError = "The saved answer couldn't retry: \(error.localizedDescription)"
            return false
        }
    }

    func applyNativeOptions(_ cfg: NativeChatConfig) {
        nativeConfig = cfg
        nativeTransport = nativeTransportFactory(cfg)
    }

    func retryLastTurn(conversationID: String? = nil) {
        guard let conversation = conversations.first(where: { $0.id == (conversationID ?? selectedID) }),
              let reply = conversation.messages.last, reply.role == .assistant, reply.state == .interrupted else { return }
        retryAnswer(reply.id)
    }

    func updateNativeToolConsent(_ enabled: Set<String>) {
        nativeEnabledToolIDs = enabled
    }

    var mentionCatalog: ComposerMentionCatalog {
        let webAvailable = VeraAPIClient.resolvedBase() != nil
        var items = [ComposerMentionCatalog.filesItem, ComposerMentionCatalog.folderItem]
            + ComposerMentionCatalog.builtIns(webAvailable: nativeSearchAvailable(), imageAvailable: NativeImageTools.resolvedBase() != nil)
            + capabilityDeclarations.map { ComposerMentionCatalog.capability($0, webAvailable: webAvailable) }
        for server in nativeMCP?.servers ?? [] {
            let allowed = server.tools.filter { nativeMCP?.authority.access.allowed($0, scope: "focused") == true }
            items.append(ComposerMentionCatalog.plugin(name: server.configuration.name, serverID: server.id,
                connected: server.connected, toolIDs: server.tools.map(\.id), allowedIDs: allowed.map(\.id)))
        }
        return ComposerMentionCatalog(items: items)
    }

    func mentionedToolIDs(in text: String) -> Set<String> {
        ComposerMentions.resolve(text, catalog: mentionCatalog)
    }

    func turnToolIDs(for text: String) -> Set<String> {
        let mentions = mentionedToolIDs(in: text)
        return NativeTurnToolAuthority(text, mentions: mentions).filter(nativeEnabledToolIDs.union(mentions))
    }

    func turnToolAuthority(for turn: NativeConversationTurn) -> (NativeTurnToolAuthority, Set<String>) {
        let text = turn.history.first(where: { $0.id == turn.userMessageID })?.text ?? ""
        let mentions = mentionedToolIDs(in: text)
        return (NativeTurnToolAuthority(text, mentions: mentions), nativeEnabledToolIDs.union(mentions))
    }

    func turnAllowsDispatch(_ turn: NativeConversationTurn, activity: NativeToolActivity) -> Bool {
        guard turnOwned(turn), turn.profile == turnProfile(for: turn.history.last?.routeNote) else { return false }
        let (authority, consented) = turnToolAuthority(for: turn)
        var allowed = NativeTaskTools.enabledIDs(authority.filter(turn.enabledToolIDs.intersection(consented)),
            hasEngine: nativeTaskEngine.base != nil, hasRepository: nativeTaskRepository != nil)
        allowed.remove(NativeWebTools.researchToolID)
        if turn.mode == .continuous { allowed.remove(NativeWebTools.searchToolID) }
        let supportsTools = activeCapabilityResolution?.profile.supportsTools ?? false
        if !(supportsTools && authority.allowsTools && turn.mode != .continuous) {
            allowed.remove(NativeFolderTools.toolID)
            allowed.remove(NativeCommandTools.toolID)
        }
        guard allowed.contains(activity.toolID) else { return false }
        if activity.toolID == NativeTaskTools.toolID { return activity.name == NativeTaskTools.toolName }
        let registry = NativeToolRegistry(definitions: nativeToolRegistry.definitions + (turn.mode == .continuous ? [] : (nativeMCP?.authority.definitions(scope: "focused") ?? []))
            + folderToolDefinitions(for: turn.conversationID, ledger: NativeFileChangeLedger(), alwaysAvailable: true)
            + commandToolDefinitions(for: turn, decision: .ask, record: { _ in }, alwaysAvailable: true))
        return registry.active(enabledIDs: allowed).contains { $0.id == activity.toolID && $0.name == activity.name }
    }

    func selectApprovedMemory(_ text: String, settings: NativeMemorySettings? = nil,
                              service: (any NativeMemoryServing)? = nil) async -> [NativeMemoryRanked] {
        let result = await retrieveApprovedMemory(text, settings: settings, service: service)
        if let trace = result.trace, let id = selectedID { memoryRetrievalTraces[id] = trace }
        return result.selected
    }

    func memorySelectionIsCurrent(_ selected: [NativeMemoryRanked]) -> Bool {
        guard !selected.isEmpty else { return true }
        guard nativeMemorySettings.enabled, let local = repository as? LocalChatRepository else { return false }
        do {
            try local.refreshDomainProjections()
            return try local.eligibleMemory(selected, bankScope: nativeMemorySettings.bankScope, sensitive: nativeMemorySettings.sensitiveHandling).count == selected.count
        }
        catch { return false }
    }

    private func turnMemoryIsCurrent(_ turn: NativeConversationTurn) async -> Bool {
        guard await turnCurrency(turn) == .current else { return false }
        guard let selected = turnMemorySelections[turn.attempt ?? turn.id], !selected.isEmpty else { return true }
        return memorySelectionIsCurrent(selected)
    }

    func performTurn(_ turn: NativeConversationTurn) {
        guard let repository, let nativeTransport, let nativeConfig,
              let location = turnLocation(turn), turnOwned(turn) else { return }
        let id = turn.conversationID
        let user = conversations[location.conversation].messages[location.user]
        let text = user.text
        let records = user.attachments
        let routeNote = user.routeNote
        parameterRejection = nil
        setTurnStatus("Thinking…", turn: turn)
        generating = true
        let sharedDefinitions = nativeToolRegistry.definitions + (turn.mode == .continuous ? [] : (nativeMCP?.authority.definitions(scope: "focused") ?? []))
        var turnRegistry = NativeToolRegistry(definitions: sharedDefinitions)
        if let service = nativeTaskService, nativeTaskEngine.base != nil,
           turnOwned(turn) {
            let origin = NativeTaskOrigin(conversationID: id,
                userMessageID: turn.userMessageID, assistantMessageID: turn.assistantMessageID)
            let profile = nativeTaskEnrollment ?? (try? nativeTaskConfiguration?.enroll(config: nativeConfig))
            if nativeTaskConfiguration == nil || profile != nil {
                let workerTypes = turnToolAuthority(for: turn).0.allowedWorkerTypes
                turnRegistry = NativeToolRegistry(definitions: sharedDefinitions + [
                    NativeTaskTools.definition(service: service, origin: origin, profile: profile,
                        searchAvailable: nativeSearchAvailable, allowedWorkerTypes: { workerTypes },
                        didSave: { [weak self] _ in await self?.reloadNativeTaskReferences() }),
                ])
            }
        }
        let turnGrants = grants(for: id)
        let folderConsented = nativeEnabledToolIDs.contains(NativeFolderTools.toolID)
        let commandsConsented = nativeEnabledToolIDs.contains(NativeCommandTools.toolID)
        let resolver = ruleResolver(for: id, requestText: text)
        if !turnGrants.isEmpty && folderConsented {
            let rules = nativeRuleSource
            turnRegistry = NativeToolRegistry(definitions: turnRegistry.definitions + folderToolDefinitions(
                for: id, ledger: fileChangeLedger(for: turn),
                edits: resolver.decision(for: .fileEdits), trash: resolver.decision(for: .trash),
                live: { rules.resolver(for: id, requestText: text).decision(for: $0) }, alwaysAvailable: true))
        }
        if !turnGrants.isEmpty && commandsConsented {
            turnRegistry = NativeToolRegistry(definitions: turnRegistry.definitions + commandToolDefinitions(
                for: turn, decision: resolver.decision(for: .commands),
                record: { [weak self] run in
                    Task { @MainActor [weak self] in
                        var scoped = run
                        scoped.id = Self.scopedBlockID(run.id, turn: turn)
                        self?.attachDisplayBlock(.commandRun(scoped), turn: turn)
                    }
                },
                alwaysAvailable: true))
        }
        let toolLoop = NativeToolLoop(
            transport: nativeTransport, registry: turnRegistry,
            authorize: { [weak self] in
                guard let self else { return false }
                return await self.turnMemoryIsCurrent(turn)
            },
            willExecute: { [weak self] activity in
                guard let self else { return false }
                return await self.prepareTurnDispatch(activity, turn: turn)
            },
            confirm: { [weak self] activity in
                guard let self else { return false }
                return await self.awaitTurnConfirmation(activity, turn: turn)
            })
        let capabilityProfile = ModelCapabilityCatalog.resolve(
            model: nativeConfig.model, overrides: nativeCapabilityOverrides).profile
        let (authority, consented) = turnToolAuthority(for: turn)
        var enabledToolIDs = capabilityProfile.supportsTools
            ? NativeTaskTools.enabledIDs(authority.filter(turn.enabledToolIDs.intersection(consented)), hasEngine: nativeTaskEngine.base != nil,
                                         hasRepository: nativeTaskRepository != nil) : []
        enabledToolIDs.remove(NativeWebTools.researchToolID)
        if turn.mode == .continuous { enabledToolIDs.remove(NativeWebTools.searchToolID) }
        if !(capabilityProfile.supportsTools && authority.allowsTools && folderConsented && !turnGrants.isEmpty && turn.mode != .continuous) {
            enabledToolIDs.remove(NativeFolderTools.toolID)
        }
        if !(capabilityProfile.supportsTools && authority.allowsTools && commandsConsented && !turnGrants.isEmpty && turn.mode != .continuous) {
            enabledToolIDs.remove(NativeCommandTools.toolID)
        }
        let grantNote = enabledToolIDs.contains(NativeFolderTools.toolID) || enabledToolIDs.contains(NativeCommandTools.toolID)
            ? NativeFolderTools.grantNote(turnGrants) : nil
        let bridgeConfig = effectiveBridgeConfig
        let bridgeTransportFactory = visionBridgeTransportFactory
        var memorySettings = turn.memorySettings
        if !nativeMemorySettings.enabled { memorySettings.enabled = false }
        let memoryService = nativeMemoryService
        let scopes = ResolvedPromptScopes(persona: turn.persona, userScope: turn.userScope, instructions: turn.instructions)
        let persona = scopes.persona
        let ownerName = nativeOwnerName
        let assistantName = self.assistantName
        let activeTools = turnRegistry.active(enabledIDs: enabledToolIDs)
        let allowedGrounding = Set(conversations.first(where: { $0.id == id })?.grounding ?? [])
        let groundingCollections = turn.grounding.filter { allowedGrounding.contains($0) }
        let groundingBase = client?.base
        groundingStatus[id] = nil
        lastRequestTrace = NativeRequestTrace.make(
            model: nativeConfig.model, streaming: nativeConfig.streaming,
            options: nativeConfig.options, timestamp: Date())
        turnExecutions[turn.id]?.deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
            guard self?.turnExecutions[turn.id]?.record.attempt == turn.attempt else { return }
            self?.stopAnswer(turn.assistantMessageID, reason: "This answer reached its time limit. You can ask a follow-up.")
        }
        turnExecutions[turn.id]?.task = Task {
            defer { turnMemorySelections[turn.attempt ?? turn.id] = nil; finishTurnExecution(turn) }
            var lastCheckpoint = Date.distantPast
            var partialAnswer = false
            do {
                try await ensureTurnCurrent(turn)
                let attachmentStore = self.attachmentStore
                let imageLoader: (MessageAttachment) -> String? = {
                    attachmentStore.requestDataURL(for: $0)
                }
                if routeNote?.route == .bridged {
                    guard let bridgeConfig else {
                        throw BridgeTurnFailure(
                            message: "The vision bridge is no longer configured. Your message and attachment are saved; nothing was sent.")
                    }
                    setTurnStatus("Describing the attachment…", turn: turn)
                    let bridge = VisionBridge(
                        config: bridgeConfig,
                        transport: bridgeTransportFactory.map { $0(bridgeConfig) })
                    var descriptions: [(name: String, text: String)] = []
                    do {
                        for record in records where record.isImage {
                            guard let dataURL = attachmentStore.requestDataURL(for: record) else {
                                throw VisionBridgeError.emptyDescription(record.name)
                            }
                            descriptions.append(
                                (record.name, try await bridge.describe(name: record.name, dataURL: dataURL)))
                        }
                    } catch {
                        throw BridgeTurnFailure(
                            message: "The vision bridge couldn't describe the attachment: \(error.localizedDescription). Your message and attachment are saved locally; nothing was sent to the model.")
                    }
                    let disclosure = VisionBridgeDisclosure.block(
                        descriptions: descriptions, bridgeModel: bridgeConfig.model)
                    try await ensureTurnCurrent(turn)
                    if let location = turnLocation(turn) {
                        let i = location.conversation
                        let userIndex = location.user
                        conversations[i].messages[userIndex].routeNote = MessageRouteNote(
                            route: .bridged, bridgeModel: bridgeConfig.model, disclosure: disclosure)
                        try? repository.saveMessage(
                            conversations[i].messages[userIndex], conversationID: id, ordinal: userIndex)
                    }
                    setTurnStatus("Thinking…", turn: turn)
                }
                var turnMessages = turn.history.map(\.message)
                if let location = turnLocation(turn), let current = turnMessages.firstIndex(where: { $0.id == turn.userMessageID }) {
                    turnMessages[current].routeNote = conversations[location.conversation].messages[location.user].routeNote
                }
                var selectedMemories: [NativeMemoryRanked] = []
                let retrieval = await retrieveApprovedMemory(text, history: turn.history.filter { $0.id != turn.userMessageID },
                                                             settings: memorySettings, service: memoryService)
                selectedMemories = retrieval.selected
                if let trace = retrieval.trace { memoryRetrievalTraces[id] = trace }
                var groundingAssembly: KnowledgeGrounding.Assembly?
                if !groundingCollections.isEmpty {
                    if let groundingBase {
                        setTurnStatus("Searching knowledge…", turn: turn)
                        groundingStatus[id] = .retrieving
                        let result = await nativeKnowledgeQuery(groundingBase, text, groundingCollections)
                        let researchActive = activeTools.contains {
                            NativeWebTools.researchCapableIDs.contains($0.id)
                        }
                        switch result {
                        case .ok(let passages) where !passages.isEmpty:
                            groundingAssembly = KnowledgeGrounding.assemble(
                                passages,
                                startAt: researchActive
                                    ? KnowledgeGrounding.numberingOffsetWithResearch + 1 : 1)
                            groundingStatus[id] = .grounded(passages.count)
                        case .ok:
                            groundingStatus[id] = .empty
                        case .unconfigured:
                            groundingStatus[id] = .unconfigured
                        case .error(let detail):
                            groundingStatus[id] = .error(detail)
                        }
                        setTurnStatus("Thinking…", turn: turn)
                    } else {
                        groundingStatus[id] = .unconfigured
                    }
                }
                if !nativeMemorySettings.enabled {
                    selectedMemories = []
                } else if let local = repository as? LocalChatRepository {
                    do { selectedMemories = try local.eligibleMemory(selectedMemories, bankScope: nativeMemorySettings.bankScope, sensitive: nativeMemorySettings.sensitiveHandling) }
                    catch {
                        selectedMemories = []
                        memoryServiceState = .retrievalUnavailable("Saved memory could not be checked before sending.")
                    }
                }
                if var finalTrace = memoryRetrievalTraces[id] {
                    finalTrace.injected = selectedMemories.enumerated().map { index, item in
                        NativeMemoryTraceEntry(id: item.record.id, title: item.record.title, source: "injected", rank: index + 1, score: item.score)
                    }
                    memoryRetrievalTraces[id] = finalTrace
                }
                var contracts = NativePresentationContract.chatDefaults
                if activeTools.contains(where: { NativeWebTools.researchCapableIDs.contains($0.id) }) {
                    contracts.insert(.citations)
                }
                if groundingAssembly != nil || !selectedMemories.isEmpty { contracts.insert(.citations) }
                try await ensureTurnCurrent(turn)
                if let location = turnLocation(turn) {
                    conversations[location.conversation].messages[location.reply].sources =
                        (groundingAssembly?.sources ?? []) + NativeMemoryCitation.sources(selectedMemories)
                }
                let assembled = NativeContextAssembler.assemble(NativeContextInput(
                    persona: persona, userScope: scopes.userScope,
                    conversationInstructions: scopes.instructions,
                    timestamp: Date(), timeZone: .current,
                    ownerName: ownerName, assistantName: assistantName, memories: selectedMemories,
                    knowledgeGrounding: groundingAssembly?.block ?? "",
                    capabilities: capabilityProfile, tools: activeTools,
                    contracts: contracts,
                    unavailableNotes: (NativeImageTools.resolvedBase() == nil ? [NativeImageTools.unavailableNote] : [])
                        + (NativeWebSearch.resolvedBase() == nil ? [NativeWebSearch.unavailableNote] : [])))
                let history = NativeChatHistoryBuilder.build(
                    messages: turnMessages, systemPrompt: assembled.prompt + (grantNote.map { "\n\n" + $0 } ?? "") + "\n\n" +
                        "Answer the user's question directly and concisely. Use at most two web lookups for current facts, then answer from the evidence or explain what remains uncertain. Only the final user message is the current request. Earlier requests are context, not permission to run their tools again. Respect the current request's tool restrictions. Start background research only when this current request explicitly asks for research or an investigation. Give a brief acknowledgment without task identifiers, implementation details, or promises about delivery format. Report real blockers when relevant. Never wait for its report or claim it is complete. Do not add progress commentary about other turns to an unrelated answer. Other accepted turns may still be working; this message does not cancel or change them.",
                    imageLoader: imageLoader, capabilities: capabilityProfile,
                    contextCeiling: nativeConfig.options.contextCeiling)
                turnMemorySelections[turn.attempt ?? turn.id] = selectedMemories
                for try await snapshot in toolLoop.stream(
                    messages: history, model: nativeConfig.model, enabledToolIDs: enabledToolIDs
                ) {
                    try await ensureTurnCurrent(turn)
                    guard let location = turnLocation(turn) else { throw CancellationError() }
                    let i = location.conversation
                    let replyIndex = location.reply
                    partialAnswer = snapshot.isPartial
                    let (afterArt, arts) = Artifact.parse(snapshot.content)
                    let (clean, ask) = VeraAsk.parse(afterArt)
                    conversations[i].messages[replyIndex].text = clean
                    conversations[i].messages[replyIndex].ask = ask
                    conversations[i].messages[replyIndex].artifacts = arts
                    conversations[i].messages[replyIndex].toolActivities = snapshot.activities
                    for activity in snapshot.activities {
                        guard let image = NativeImageTools.attachment(from: activity),
                              !conversations[i].messages[replyIndex].attachments.contains(where: { $0.fileName == image.fileName }) else { continue }
                        conversations[i].messages[replyIndex].attachments.append(image)
                    }
                    let lifted = NativeResearchSources.lift(snapshot.activities)
                    if !lifted.isEmpty {
                        conversations[i].messages[replyIndex].sources =
                            NativeMemoryCitation.merging(lifted, grounding: groundingAssembly?.sources ?? [], memories: selectedMemories)
                    }
                    if let latest = arts.last,
                       latest.id != activeArtifact?.id || latest.content != activeArtifact?.content {
                        openArtifact(latest)
                    }
                    setTurnStatus(snapshot.activities.last(where: { $0.state == .pending })
                        .map { "Using \($0.title)…" }, turn: turn)
                    if Date().timeIntervalSince(lastCheckpoint) >= 0.25 {
                        try turnRepository?.checkpointTurn(turn,
                            message: conversations[i].messages[replyIndex], ordinal: replyIndex)
                        lastCheckpoint = Date()
                    }
                }
                try Task.checkCancellation()
                try await ensureTurnCurrent(turn)
                setTurnStatus(nil, turn: turn)
                if let location = turnLocation(turn) {
                    let i = location.conversation
                    let replyIndex = location.reply
                    conversations[i].messages[replyIndex].state = partialAnswer ? .interrupted : .complete
                    conversations[i].messages[replyIndex].failure = partialAnswer
                        ? "This answer is unfinished. You can ask a follow-up or retry the answer." : nil
                    conversations[i].updatedAt = Date()
                    try turnRepository?.finishTurn(turn.id, attempt: turn.attempt, state: partialAnswer ? .interrupted : .complete,
                        message: conversations[i].messages[replyIndex], ordinal: replyIndex)
                    try repository.saveConversation(conversations[i])
                    if !partialAnswer, conversations[i].messages[replyIndex].id
                        == conversations[i].messages.first(where: { $0.role == .assistant })?.id {
                        generateTitleIfNeeded(conversationID: id)
                    }
                    if repository is any NativeMemoryRepository {
                        let completedAssistant = conversations[i].messages[replyIndex]
                        let conversationExcluded = conversations[i].memoryExcluded
                        let userIndex = location.user
                        let sourceDate = conversations[i].messages.indices.contains(userIndex)
                            ? conversations[i].messages[userIndex].createdAt : Date()
                        Task {
                            await self.learnFromCompletedTurn(
                                user: text, assistant: completedAssistant,
                                source: NativeMemoryTurnSource(conversationID: id, messageID: turn.userMessageID.uuidString, date: sourceDate),
                                turnKey: id + "|" + turn.userMessageID.uuidString,
                                conversationExcluded: conversationExcluded)
                        }
                    }
                }
            } catch {
                guard await turnCurrency(turn) == .current else { return }
                setTurnStatus(nil, turn: turn)
                if let rejection = ModelParameterRejectionClassifier.classify(
                    error: error, options: nativeConfig.options) {
                    parameterRejection = NativeParameterRejectionPrompt(
                        rejection: rejection, model: nativeConfig.model,
                        detail: error.localizedDescription, conversationID: id)
                }
                if let location = turnLocation(turn) {
                    let i = location.conversation
                    let replyIndex = location.reply
                    let userIndex = location.user
                    conversations[i].messages[replyIndex].state = .interrupted
                    conversations[i].messages[replyIndex].failure = error is CancellationError
                        ? "This answer stopped before another step could run. Check its settings before retrying."
                        : error.localizedDescription
                    conversations[i].updatedAt = Date()
                    if userIndex >= 0, userIndex < conversations[i].messages.count,
                       conversations[i].messages[userIndex].routeNote?.route == .bridged,
                       conversations[i].messages[userIndex].routeNote?.disclosure == nil {
                        conversations[i].messages[userIndex].routeNote = nil
                        try? repository.saveMessage(
                            conversations[i].messages[userIndex], conversationID: id, ordinal: userIndex)
                    }
                    try? turnRepository?.finishTurn(turn.id, attempt: turn.attempt, state: .interrupted,
                        message: conversations[i].messages[replyIndex], ordinal: replyIndex)
                    try? repository.saveConversation(conversations[i])
                }
            }
        }
    }

}

enum NativeMemorySourceState: Equatable, Sendable {
    case ok
    case edited
    case deleted
    case excluded

    var message: String {
        switch self {
        case .ok: ""
        case .edited: "This message changed after Vera remembered it."
        case .deleted: "The source message was deleted, so Vera opened the conversation instead."
        case .excluded: "This conversation is excluded from memory suggestions."
        }
    }
}

enum NativeMemorySourceSnapshot: Equatable, Sendable {
    case untracked
    case missing
    case text(String)
}

struct NativeMemorySourceNotice: Equatable, Sendable {
    let conversationID: String
    let state: NativeMemorySourceState
    let message: String
}

enum NativeMemorySourceConsentError: Error, LocalizedError {
    case sourceChanged

    var errorDescription: String? {
        "The message this suggestion came from changed or was removed. Dismiss it and review the conversation again."
    }
}
