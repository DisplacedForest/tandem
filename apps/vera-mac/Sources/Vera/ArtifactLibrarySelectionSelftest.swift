import Foundation

enum ArtifactLibrarySelectionSelftest {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static func record(_ id: String, _ kind: ArtifactKind, _ title: String, conversation: String? = nil, origin: String? = nil) -> ArtifactRecord {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return ArtifactRecord(id: id, kind: kind, title: title, conversationID: conversation, originTitle: origin,
                              createdAt: date, updatedAt: date, versionCount: 1)
    }

    @MainActor
    static func run() throws {
        let report = record("doc-a", .document, "Heating report", conversation: "garden", origin: "Greenhouse plan")
        let notes = record("doc-b", .document, "Trip notes", conversation: "travel", origin: "Summer trip")
        let dusk = record("img-a", .image, "Greenhouse at dusk", conversation: "garden", origin: "Greenhouse plan")
        let beach = record("img-b", .image, "Beach sketch", conversation: "travel", origin: "Summer trip")
        let beds = record("file-a", .fileChange, "beds.md", conversation: "garden", origin: "Greenhouse plan")
        let calendar = record("canvas-a", .canvas, "Planting calendar")
        let records = [report, notes, dusk, beach, beds, calendar]

        var state = ArtifactLibrarySelection()
        try check(state.visible(records).map(\.id) == records.map(\.id), "With no filters every record is visible in input order")
        let reversed = Array(records.reversed())
        try check(state.visible(reversed).map(\.id) == reversed.map(\.id), "Visible keeps whatever order it is given")
        state.filter = .image
        try check(state.visible(records).map(\.id) == ["img-a", "img-b"], "The image filter keeps images in input order")

        state = ArtifactLibrarySelection()
        state.reconcile([])
        try check(state.selectedID == nil && state.selected(in: []) == nil, "Zero results leave nothing selected")
        state.reconcile([calendar])
        try check(state.selectedID == "canvas-a" && state.selected(in: [calendar])?.id == "canvas-a", "One result is selected")
        state = ArtifactLibrarySelection()
        state.reconcile(records)
        try check(state.selectedID == "doc-a", "Many results select the first visible item")

        state = ArtifactLibrarySelection(selectedID: "img-a")
        state.search = "greenhouse"
        state.reconcile(records)
        try check(state.selectedID == "img-a", "A selection matching the search stays selected")
        state.filter = .image
        state.reconcile(records)
        try check(state.selectedID == "img-a" && state.selected(in: records)?.id == "img-a", "A selection matching the filter stays selected")

        state = ArtifactLibrarySelection(selectedID: "doc-a")
        state.filter = .image
        try check(state.selected(in: records) == nil, "Before reconciling, a hidden document is not shown")
        try check(state.resolved(in: records)?.id == "img-a", "The resolved selection is already the first image")
        state.reconcile(records)
        try check(state.selectedID == "img-a", "Switching a selected document to images selects the first image")
        try check(state.selected(in: records)?.id == "img-a" && state.selected(in: records)?.kind == .image, "The detail shows that image")

        state = ArtifactLibrarySelection(selectedID: "doc-a")
        state.search = "beach"
        state.reconcile(records)
        try check(state.selectedID == "img-b", "A selection excluded by search moves to the first match")

        state = ArtifactLibrarySelection(selectedID: "doc-a")
        state.conversationFilter = "travel"
        state.reconcile(records)
        try check(state.selectedID == "doc-b", "A selection excluded by the conversation filter moves to the first item of that conversation")

        state = ArtifactLibrarySelection(selectedID: "img-a")
        state.conversationFilter = "garden"
        state.reconcile(records)
        try check(state.selectedID == "img-a", "The conversation filter alone keeps a matching image")
        state.filter = .fileChange
        state.reconcile(records)
        try check(state.selectedID == "file-a", "Combining a conversation and kind filter that excludes the selection moves to the first match")

        state.filter = .all
        state.conversationFilter = nil
        state.search = ""
        state.reconcile(records)
        try check(state.selectedID == "file-a", "Clearing filters keeps the current selection")

        state.search = "no such thing"
        state.reconcile(records)
        try check(state.selectedID == nil && state.selected(in: records) == nil && state.resolved(in: records) == nil, "Zero results clear the selection")
        try check(state.visible(records).isEmpty, "Zero results show no rows")
        state.search = ""
        state.filter = .canvas
        state.reconcile(records)
        try check(state.selectedID == "canvas-a", "Loosening the filter selects the first visible item")

        state = ArtifactLibrarySelection(selectedID: "img-a")
        state.reconcile(records)
        let withoutDusk = records.filter { $0.id != "img-a" }
        state.reconcile(withoutDusk)
        try check(state.selectedID == "doc-a", "Removing the selected record selects the first visible item")
        state = ArtifactLibrarySelection(selectedID: "img-b")
        let added = [record("doc-new", .document, "New report")] + records.filter { $0.id != "doc-b" }
        state.reconcile(added)
        try check(state.selectedID == "img-b", "A still-present selection survives other records being added and removed")
        state.filter = .image
        state.reconcile(records.filter { $0.id != "img-b" })
        try check(state.selectedID == "img-a", "Removing the selected image under a filter selects the first remaining image")

        state = ArtifactLibrarySelection(selectedID: "img-a")
        state.conversationFilter = "travel"
        try check(state.selected(in: records) == nil, "A selected record that exists but is hidden is not selected")

        state = ArtifactLibrarySelection(selectedID: "doc-b", conversationFilter: "travel")
        try check(state.open("img-a", in: records), "Opening an existing record succeeds")
        try check(state.conversationFilter == nil && state.selected(in: records)?.id == "img-a", "Opening drops a conversation filter that hides the target")

        state = ArtifactLibrarySelection(selectedID: "img-a", filter: .image, conversationFilter: "garden")
        try check(state.open("file-a", in: records), "Opening under a kind filter succeeds")
        try check(state.filter == .all && state.conversationFilter == "garden", "Opening drops only the kind filter when the conversation still matches")
        try check(state.selected(in: records)?.id == "file-a", "The opened file change is visible and selected")

        state = ArtifactLibrarySelection(selectedID: "img-b", filter: .image, conversationFilter: "travel")
        try check(state.open("doc-a", in: records), "Opening under both filters succeeds")
        try check(state.filter == .all && state.conversationFilter == nil && state.selected(in: records)?.id == "doc-a", "Opening drops both filters that hide the target")

        state = ArtifactLibrarySelection(selectedID: "img-b", search: "beach", filter: .image)
        try check(state.open("img-a", in: records), "Opening with a search active succeeds")
        try check(state.search.isEmpty && state.filter == .image && state.selected(in: records)?.id == "img-a", "Opening clears the search and keeps a compatible kind filter")

        state = ArtifactLibrarySelection(selectedID: "missing", filter: .image)
        try check(!state.open("gone", in: records), "Opening a missing record reports failure")
        try check(state.selectedID == "img-a" && state.selected(in: records)?.id == "img-a", "Opening a missing record leaves a valid reconciled selection")
        state = ArtifactLibrarySelection(search: "no such thing")
        try check(!state.open("gone", in: records) && state.selectedID == nil, "Opening a missing record with no matches selects nothing")

        state = ArtifactLibrarySelection(selectedID: "canvas-a", search: "calendar", filter: .canvas)
        state.adoptConversation("travel", in: records)
        try check(state.conversationFilter == "travel" && state.search.isEmpty && state.filter == .all, "Adopting a conversation clears search and the kind filter")
        try check(state.selectedID == "doc-b" && state.selected(in: records)?.id == "doc-b", "Adopting a conversation selects its first item")

        state = ArtifactLibrarySelection(selectedID: "doc-b", search: "trip")
        state.apply(conversation: "travel", open: "img-a", in: records)
        try check(state.selected(in: records)?.id == "img-a", "An open request arriving with a conversation filter still ends on the opened item")
        try check(state.conversationFilter == nil && state.search.isEmpty, "The conversation filter that would hide the opened item is dropped")

        state = ArtifactLibrarySelection(selectedID: "doc-b")
        state.apply(conversation: "garden", open: "file-a", in: records)
        try check(state.conversationFilter == "garden" && state.selected(in: records)?.id == "file-a", "A compatible conversation filter is kept when both arrive together")

        state = ArtifactLibrarySelection(selectedID: "doc-b")
        state.apply(conversation: "garden", open: "gone", in: records)
        try check(state.conversationFilter == "garden" && state.selected(in: records)?.id == "doc-a", "A missing target with a conversation filter falls back to that conversation's first item")

        state = ArtifactLibrarySelection(selectedID: "doc-b")
        state.apply(conversation: nil, open: nil, in: records)
        try check(state == ArtifactLibrarySelection(selectedID: "doc-b"), "No pending request changes nothing")

        try check(ArtifactLibrarySelection.companionFilterTitle(name: ConfigStore.defaultAssistantName) == "From your companion",
                  "An unnamed companion is your companion in the filter label")
        try check(ArtifactLibrarySelection.companionFilterTitle(name: "  ") == "From your companion", "A blank name is your companion")
        try check(ArtifactLibrarySelection.companionFilterTitle(name: "Juniper") == "From Juniper", "A chosen name is used in the filter label")

        print("  artifact library selection OK")
    }
}
