import Foundation
import SwiftUI

extension SelfTest {
    @MainActor
    static func runCompanionTranscriptContinuity() throws {
        let defaults = AppLocations.scratchPreferences()
        let require = NativeTaskFixture.require
        let messages = [UUID(), UUID(), UUID()]
        let continuity = CompanionTranscriptContinuity(defaults: defaults)
        try require(continuity.begin(conversationID: "first", messages: messages) == nil, "A new transcript opens at latest")
        continuity.scrollPhaseChanged(.interacting)
        continuity.observe(nearBottom: false, conversationID: "first")
        continuity.observe(visible: [messages[0]], ordered: messages, conversationID: "first")
        try require(continuity.position.followsLatest, "Initial layout cannot overwrite restored position")
        continuity.finishRestoring(conversationID: "first")
        try require(continuity.shouldFollowLatest, "Streaming follows latest when first opened")
        continuity.scrollPhaseChanged(.animating)
        continuity.observe(nearBottom: false, conversationID: "first")
        try require(continuity.shouldFollowLatest, "Programmatic animation never arms position writeback")
        continuity.scrollPhaseChanged(.interacting)
        continuity.observe(visible: [messages[1], messages[2]], ordered: messages, conversationID: "first")
        continuity.observe(nearBottom: false, conversationID: "first")
        try require(!continuity.shouldFollowLatest, "Reading earlier messages prevents streaming from pulling to bottom")
        let restarted = CompanionTranscriptContinuity(defaults: defaults)
        try require(restarted.begin(conversationID: "first", messages: messages) == messages[1], "Relaunch restores the first visible message")
        restarted.observe(nearBottom: true, conversationID: "first")
        try require(restarted.position.messageID == messages[1] && !restarted.position.followsLatest, "Restoration geometry does not erase saved history position")
        restarted.finishRestoring(conversationID: "first")
        restarted.scrollPhaseChanged(.interacting)
        restarted.observe(nearBottom: true, conversationID: "first")
        try require(restarted.shouldFollowLatest, "Returning to latest resumes following replies")
        restarted.scrollPhaseChanged(.idle)
        restarted.observe(nearBottom: false, conversationID: "first")
        restarted.observe(visible: [messages[0]], ordered: messages, conversationID: "first")
        try require(restarted.shouldFollowLatest && restarted.position.messageID == messages[1],
                    "Content growth at rest cannot change the reading anchor or stop following latest")
        try require(restarted.begin(conversationID: "second", messages: messages) == nil, "Another conversation has independent position")
        restarted.finishRestoring(conversationID: "second")
        restarted.scrollPhaseChanged(.interacting)
        restarted.observe(nearBottom: false, conversationID: "first")
        try require(restarted.shouldFollowLatest, "A stale view callback cannot modify another conversation")
        try require(continuity.begin(conversationID: "first", messages: messages) == nil, "Navigation restores updated latest preference")
        continuity.finishRestoring(conversationID: "first")
        continuity.scrollPhaseChanged(.interacting)
        continuity.observe(visible: [messages[1]], ordered: messages, conversationID: "first")
        continuity.observe(nearBottom: false, conversationID: "first")
        try require(restarted.begin(conversationID: "first", messages: [messages[0]]) == nil,
                    "Removed anchor falls back to latest without mutating transcript")
        let unavailable = ChatStore(nativeConfig: nil, nativeTransport: nil,
                                    repository: try LocalChatRepository(inMemory: true), artifactPersistenceEnabled: false)
        unavailable.loadDotProfile()
        unavailable.ensureVeraThread()
        unavailable.openVeraThread()
        try require(unavailable.companionOpeningError?.contains("Settings") == true && unavailable.conversationTurns.isEmpty,
                    "Missing connection shows an action without admitting a forever-pending opening")
        let missingHistory = ChatStore(nativeConfig: nil, nativeTransport: nil, repository: nil, artifactPersistenceEnabled: false)
        try require(missingHistory.companionOpeningError?.contains("Reopen Tandem") == true,
                    "Missing history has a recovery action instead of a permanent spinner")
        print("companion transcript continuity: PASS")
    }
}
