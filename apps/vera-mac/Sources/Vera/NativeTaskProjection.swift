import Foundation

enum NativeTaskProjection {
    static let carryOnChoices: Set<String> = ["continue", "finish"]

    static func carriesOn(_ snapshot: NativeTaskSnapshot) -> Bool {
        guard snapshot.state == .needsDecision, let choices = snapshot.decision?.choices else { return false }
        return choices.count == carryOnChoices.count && Set(choices) == carryOnChoices
    }

    static func display(reference: NativeTaskReference, snapshot: NativeTaskSnapshot?,
                        connectionNote: String? = nil, retryPending: Bool = false)
        throws -> (card: NativeTaskCardPresentation, artifact: NativeResearchArtifact?) {
        let id = reference.id.uuidString
        let dot = reference.createRequest.workerType == "companion"
        let document = reference.createRequest.workerType == "document" || dot
        let work = dot ? "Work" : document ? "Writing" : "Research"
        var card = NativeTaskCardPresentation(
            id: id, title: reference.request.displayTitle, status: .preparing,
            milestone: "The request is saved here.", connectionNote: connectionNote.map(SavedWording.current),
            canCancel: true, workerType: reference.createRequest.workerType)
        guard let snapshot else {
            if reference.deliveryState == .rejected {
                card.status = .failed
                card.milestone = reference.lastDeliveryError.map(SavedWording.current) ?? "\(work) couldn't start."
                card.canCancel = false
            } else if reference.cancelRequested {
                card.status = .stopping
                card.milestone = "Waiting to confirm that \(work.lowercased()) has stopped."
                card.canCancel = false
            } else if let error = reference.lastDeliveryError {
                card.connectionNote = SavedWording.current(error)
            }
            return (card, nil)
        }
        guard snapshot.id == reference.remoteTaskID, snapshot.workerType == reference.createRequest.workerType else {
            throw NativeTaskHTTPError.invalidResponse
        }
        let sources = document ? [] : try displaySources(snapshot.checkpoint.sources)
        card.sources = sources
        card.canCancel = !snapshot.state.isTerminal && !reference.cancelRequested && !snapshot.cancelRequested
        let count = sources.count
        let sourcePhrase = "\(count) \(count == 1 ? "source" : "sources")"
        let saved = document ? documentProgress(snapshot.checkpoint) : nil
        if (reference.cancelRequested || snapshot.cancelRequested) && !snapshot.state.isTerminal {
            card.status = .stopping
            if document {
                card.milestone = saved.map { "Stopping. \($0)" } ?? "Stopping the current step."
            } else {
                card.milestone = count > 0 ? "Stopping research. Saved \(sourcePhrase)." : "Stopping the current step."
            }
            return (card, nil)
        }
        switch snapshot.state {
        case .queued, .running:
            card.status = snapshot.state == .running ? .working : .queued
            if dot {
                card.milestone = "Working on it."
            } else if document {
                card.milestone = documentMilestone(snapshot.checkpoint)
            } else {
                switch snapshot.checkpoint.phase {
                case "gather":
                    card.milestone = count > 0 ? "Gathered \(sourcePhrase). Checking the remaining questions." : "Looking for useful sources."
                case "rag": card.milestone = "Checking saved knowledge alongside the gathered sources."
                case "synthesize":
                    card.milestone = count > 0 ? "Preparing the report from \(sourcePhrase)." : "Checking whether enough evidence is available."
                default: card.milestone = "Planning the research."
                }
            }
        case .blocked:
            card.status = .queued
            if snapshot.checkpoint.nativeUnavailable != nil {
                card.milestone = reference.profile?.requiresCredential == true
                    ? "Keep Tandem open with the original model profile and its saved credential. \(work) will continue when it is available."
                    : "Keep Tandem open with the original model profile. \(work) will continue when it is available."
            } else {
                card.milestone = "Waiting for \(work.lowercased()) to become available again."
            }
        case .needsDecision:
            guard let decision = snapshot.decision, !decision.id.isEmpty,
                  decision.prompt.unicodeScalars.count <= 2000 else {
                throw NativeTaskHTTPError.invalidResponse
            }
            if dot, carriesOn(snapshot) {
                card.status = .working
                card.milestone = "Working on it."
                break
            }
            card.status = .needsInput
            card.milestone = retryPending ? "Your retry is saved. Waiting to continue."
                : decision.prompt
            card.canRetry = decision.choices.contains("retry") && !retryPending
            if dot, !retryPending, let details = decision.details, details.unicodeScalars.count <= 20000 { card.details = details }
            if dot, !retryPending { card.covers = CardAnswers.shown(decision.covers) }
            if dot, !retryPending { card.neverTitle = CardAnswers.shown(decision.never) }
        case .failed:
            card.status = .failed
            let again = dot ? "Start the work again" : document ? "Start a new document" : "Start a new research request"
            switch snapshot.checkpoint.failureReason {
            case "input_limit" where dot: card.milestone = "The assignment and its notes are too large. Start the work again with less."
            case "input_limit": card.milestone = document ? "The brief, inputs or outline are too large. Start a new document with a shorter brief." : "The research input is too large. Start a smaller research request."
            case "request_conflict": card.milestone = "The saved request could not be resumed safely. \(again)."
            default:
                if dot {
                    card.milestone = "I couldn't finish this."
                } else if document {
                    card.milestone = saved.map { "Writing couldn't finish. \($0)" } ?? "Writing couldn't finish."
                } else {
                    card.milestone = count > 0 ? "Research couldn't finish. The gathered sources are saved." : "Research couldn't finish."
                }
            }
        case .canceled:
            card.status = .stopped
            if dot {
                let unsure = snapshot.checkpoint.unconfirmedEffects
                card.milestone = unsure.isEmpty ? "Stopped." : "Stopped. Check whether this finished: " + unsure.joined(separator: "; ") + "."
            } else if document {
                card.milestone = saved.map { "Stopped. \($0)" } ?? "Stopped before any sections were written."
            } else {
                card.milestone = count > 0 ? "Stopped with \(sourcePhrase) saved." : "Stopped before any sources were saved."
            }
        case .completed where dot:
            guard let result = snapshot.result, result.query == reference.request.objective,
                  result.kind == "companion_report",
                  result.report.unicodeScalars.count <= NativeCompanionWorker.reportScalars,
                  (result.summary ?? "").unicodeScalars.count <= 2000,
                  (result.title ?? "").unicodeScalars.count <= 200,
                  [nil, NativeCompanionShape.answer, NativeCompanionShape.document].contains(result.shape) else {
                throw NativeTaskHTTPError.invalidResponse
            }
            let companionSources = try displaySources(result.sources)
            card.status = .completed
            card.sources = companionSources
            card.why = result.why
            if let stop = result.stop, stop.drawable {
                card.stop = stop
                card.milestone = ""
                return (card, nil)
            }
            if result.shape == NativeCompanionShape.answer {
                let answer = result.report.trimmingCharacters(in: .whitespacesAndNewlines)
                card.milestone = answer.isEmpty ? "Finished." : ""
                card.answer = answer.isEmpty ? nil : answer
                return (card, nil)
            }
            let summary = CitationResolver.scan(result.summary ?? "", known: Set(companionSources.map(\.n))).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            card.milestone = summary.isEmpty ? "Finished." : String(summary.prefix(280))
            guard !result.report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (card, nil) }
            return (card, NativeResearchArtifact(
                id: snapshot.id, title: reference.request.displayTitle,
                report: result.report, sources: companionSources, kind: "document"))
        case .completed:
            guard let result = snapshot.result, result.query == reference.request.objective,
                  !result.report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NativeTaskHTTPError.invalidResponse
            }
            if document {
                guard result.kind == "document_report", result.sources.isEmpty,
                      result.report.unicodeScalars.count <= NativeDocumentWorker.reportCharacters else {
                    throw NativeTaskHTTPError.invalidResponse
                }
                card.status = .completed
                card.milestone = "The document is ready."
                return (card, NativeResearchArtifact(
                    id: snapshot.id, title: reference.request.displayTitle,
                    report: result.report, sources: [], kind: "document"))
            }
            guard result.kind == "research_report", result.report.unicodeScalars.count <= 16000 else {
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

    static func answerDocument(_ card: NativeTaskCardPresentation) -> NativeResearchArtifact? {
        guard card.isCompanion, card.status == .completed,
              let answer = card.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else { return nil }
        return NativeResearchArtifact(id: card.id, title: card.title, report: answer, sources: card.sources, kind: "document")
    }

    static func documentProgress(_ checkpoint: NativeTaskCheckpoint) -> String? {
        let planned = checkpoint.outline.count
        guard planned > 0 else { return nil }
        let written = max(checkpoint.revisions.count, checkpoint.drafts.count)
        let sectionWord = written == 1 ? "section" : "sections"
        return written > 0 ? "Saved \(written) \(sectionWord) of \(planned)." : "The outline is saved."
    }

    static func documentMilestone(_ checkpoint: NativeTaskCheckpoint) -> String {
        let planned = checkpoint.outline.count
        switch checkpoint.phase {
        case "draft":
            guard planned > 0 else { return "Planning the outline." }
            return "Drafting section \(min(checkpoint.drafts.count + 1, planned)) of \(planned)."
        case "revise":
            guard planned > 0 else { return "Planning the outline." }
            return "Revising section \(min(checkpoint.revisions.count + 1, planned)) of \(planned)."
        case "assemble": return "Putting the document together."
        default: return "Planning the outline."
        }
    }

    static func displaySources(_ sources: [NativeTaskSource]) throws -> [PulseSource] {
        guard sources.count <= 14, Set(sources.map(\.n)).count == sources.count else {
            throw NativeTaskHTTPError.invalidResponse
        }
        return try sources.map { source in
            guard (1...14).contains(source.n), source.title.unicodeScalars.count <= NativeTaskSource.labelScalars,
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
