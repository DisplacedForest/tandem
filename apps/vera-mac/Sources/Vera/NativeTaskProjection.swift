import Foundation

enum NativeTaskProjection {
    static func display(reference: NativeTaskReference, snapshot: NativeTaskSnapshot?,
                        connectionNote: String? = nil, retryPending: Bool = false)
        throws -> (card: NativeTaskCardPresentation, artifact: NativeResearchArtifact?) {
        let id = reference.id.uuidString
        var card = NativeTaskCardPresentation(
            id: id, title: reference.request.objective, status: .preparing,
            milestone: "The request is saved here.", connectionNote: connectionNote,
            canCancel: true)
        guard let snapshot else {
            if reference.deliveryState == .rejected {
                card.status = .failed
                card.milestone = reference.lastDeliveryError ?? "Research couldn't start."
                card.canCancel = false
            } else if reference.cancelRequested {
                card.status = .stopping
                card.milestone = "Waiting to confirm that research has stopped."
                card.canCancel = false
            } else if let error = reference.lastDeliveryError {
                card.connectionNote = error
            }
            return (card, nil)
        }
        guard snapshot.id == reference.remoteTaskID, snapshot.workerType == "research" else {
            throw NativeTaskHTTPError.invalidResponse
        }
        let sources = try displaySources(snapshot.checkpoint.sources)
        card.sources = sources
        card.canCancel = !snapshot.state.isTerminal && !reference.cancelRequested && !snapshot.cancelRequested
        let count = sources.count
        let sourcePhrase = "\(count) \(count == 1 ? "source" : "sources")"
        if (reference.cancelRequested || snapshot.cancelRequested) && !snapshot.state.isTerminal {
            card.status = .stopping
            card.milestone = count > 0 ? "Stopping research. Saved \(sourcePhrase)." : "Stopping the current step."
            return (card, nil)
        }
        switch snapshot.state {
        case .queued, .running:
            card.status = snapshot.state == .running ? .working : .queued
            switch snapshot.checkpoint.phase {
            case "gather":
                card.milestone = count > 0 ? "Gathered \(sourcePhrase). Checking the remaining questions." : "Looking for useful sources."
            case "rag": card.milestone = "Checking saved knowledge alongside the gathered sources."
            case "synthesize":
                card.milestone = count > 0 ? "Preparing the report from \(sourcePhrase)." : "Checking whether enough evidence is available."
            default: card.milestone = "Planning the research."
            }
        case .blocked:
            card.status = .queued
            if snapshot.checkpoint.nativeUnavailable != nil {
                card.milestone = reference.profile?.requiresCredential == true
                    ? "Keep Vera open with the original model profile and its saved credential. Research will continue when it is available."
                    : "Keep Vera open with the original model profile. Research will continue when it is available."
            } else {
                card.milestone = "Waiting for research to become available again."
            }
        case .needsDecision:
            guard let decision = snapshot.decision, !decision.id.isEmpty,
                  decision.prompt.unicodeScalars.count <= 2000 else {
                throw NativeTaskHTTPError.invalidResponse
            }
            card.status = .needsInput
            card.milestone = retryPending ? "Your retry is saved. Waiting to continue." : decision.prompt
            card.canRetry = decision.choices.contains("retry") && !retryPending
        case .failed:
            card.status = .failed
            switch snapshot.checkpoint.failureReason {
            case "request_limit": card.milestone = "This task reached its model request limit. Start a new research request to continue."
            case "input_limit": card.milestone = "The research input is too large for this task. Start a smaller research request."
            case "request_conflict": card.milestone = "The saved research request could not be resumed safely. Start a new research request."
            default: card.milestone = count > 0 ? "Research couldn't finish. The gathered sources are saved." : "Research couldn't finish."
            }
        case .canceled:
            card.status = .stopped
            card.milestone = count > 0 ? "Stopped with \(sourcePhrase) saved." : "Stopped before any sources were saved."
        case .completed:
            guard let result = snapshot.result, result.kind == "research_report",
                  result.query == reference.request.objective,
                  !result.report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  result.report.unicodeScalars.count <= 16000 else {
                throw NativeTaskHTTPError.invalidResponse
            }
            let resultSources = try displaySources(result.sources)
            try validateCitations(result.report, sources: resultSources)
            card.status = .completed
            card.milestone = "The report is ready."
            card.sources = resultSources
            return (card, NativeResearchArtifact(
                id: snapshot.id, title: reference.request.objective,
                report: result.report, sources: resultSources))
        }
        return (card, nil)
    }

    static func displaySources(_ sources: [NativeTaskSource]) throws -> [PulseSource] {
        guard sources.count <= 14, Set(sources.map(\.n)).count == sources.count else {
            throw NativeTaskHTTPError.invalidResponse
        }
        return try sources.map { source in
            guard (1...14).contains(source.n), source.title.unicodeScalars.count <= 200,
                  source.url.unicodeScalars.count <= 1024 else {
                throw NativeTaskHTTPError.invalidResponse
            }
            let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return PulseSource(n: source.n, title: title.isEmpty ? "Saved reference" : title,
                               url: NativeResearchReportSafety.destination(source.url)?.absoluteString ?? "local")
        }
    }

    private static func validateCitations(_ report: String, sources: [PulseSource]) throws {
        let expression = try NSRegularExpression(pattern: "\\[([0-9]+)\\]")
        let text = report as NSString
        let matches = expression.matches(in: report, range: NSRange(location: 0, length: text.length))
        let indices = Set(sources.map { String($0.n) })
        guard !matches.isEmpty, matches.allSatisfy({ match in
            let number = text.substring(with: match.range(at: 1)).drop(while: { $0 == "0" })
            return indices.contains(number.isEmpty ? "0" : String(number))
        }) else { throw NativeTaskHTTPError.invalidResponse }
    }
}
