import Foundation

@MainActor
struct NativeComposerRoute {
    let store: ChatStore
    let assistant: NativePiPresentation?
    var allowsAttachments: Bool { assistant == nil }
    var draft: String {
        get { assistant?.draft ?? store.draft }
        nonmutating set {
            if let assistant { assistant.draft = newValue } else { store.draft = newValue }
        }
    }
    var canSend: Bool {
        if let assistant { return assistant.canSend }
        return store.canSubmitChat && (!store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.attachments.isEmpty)
    }
    func send() {
        guard canSend else { return }
        if let assistant { assistant.send() } else { store.send() }
    }
    @discardableResult
    func addFiles(_ urls: [URL]) -> Bool {
        guard allowsAttachments else { return false }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        store.addFiles(files)
        return true
    }
    func cancelPendingSend() { if assistant == nil { store.cancelPendingSend() } }
    func confirmWithoutAttachments() { if assistant == nil { store.confirmSendWithoutAttachments() } }
    func clearParameterRejection() { if assistant == nil { store.parameterRejection = nil } }
}
