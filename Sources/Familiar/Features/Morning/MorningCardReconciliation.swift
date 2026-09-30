import Foundation

/// Reconciles observed source facts with continuing human decisions. Missing items do nothing.
enum MorningCardReconciliation {
    static func apply(observations: [CardObservation], proposals: [CardProposal], runIDs: [UUID], at: Date,
                      to workspace: inout MorningWorkspace) throws -> CardGenerationSummary {
        let processed = Set((workspace.cardGenerations ?? []).flatMap(\.runIDs))
        let freshRuns = Set(runIDs).subtracting(processed)
        guard !freshRuns.isEmpty else { return CardGenerationSummary() }
        var newest: [String: CardObservation] = [:]
        for observation in observations where freshRuns.contains(observation.runID) {
            try require(!observation.itemKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !observation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !observation.identityEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "A card observation needs an item key, title and matching evidence.")
            try require(observation.observedAt.timeIntervalSince1970.isFinite, "A card observation has an invalid time.")
            if observation.state != .unknown {
                try require(!observation.stateEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "An observed open or resolved state needs evidence.")
            }
            if let previous = newest[observation.id], previous.observedAt >= observation.observedAt { continue }
            newest[observation.id] = observation
        }
        var proposed: [String: CardProposal] = [:]
        for proposal in proposals {
            try require(observations.contains { $0.id == proposal.observationKey }, "A generated proposal does not refer to collected evidence.")
            try require(proposed[proposal.observationKey] == nil, "A source item has more than one proposed card.")
            proposed[proposal.observationKey] = proposal
        }
        var summary = CardGenerationSummary()
        for observation in newest.values.sorted(by: { $0.id < $1.id }) {
            let proposal = proposed[observation.id]
            if let index = workspace.cards.firstIndex(where: { $0.tracking?.key == observation.id }) {
                var card = workspace.cards[index]
                guard var tracking = card.tracking, observation.observedAt > tracking.lastSeenAt else { continue }
                let before = card
                tracking.lastSeenAt = observation.observedAt
                tracking.lastRunID = observation.runID
                tracking.sourceName = observation.sourceName
                tracking.identityEvidence = observation.identityEvidence
                let changedFacts = tracking.contentFingerprint != observation.fingerprint
                tracking.contentFingerprint = observation.fingerprint
                if !tracking.resolvedByUser && observation.state != .unknown {
                    tracking.resolution = observation.state
                    tracking.resolutionEvidence = observation.stateEvidence
                }
                if let proposal, !tracking.userEdited { apply(proposal, to: &card) }
                card.sources = [source(for: observation, id: card.sources.first?.id ?? UUID())]
                let resolvedNow = tracking.resolution == .resolved && before.tracking?.resolution != .resolved
                let reopenedNow = tracking.resolution != .resolved && before.tracking?.resolution == .resolved
                let changedProposal = card.title != before.title || card.summary != before.summary || card.rationale != before.rationale
                    || card.timing != before.timing || card.unknowns != before.unknowns || card.action != before.action
                    || card.alternatives != before.alternatives
                if resolvedNow || reopenedNow || changedFacts || changedProposal {
                    let message = resolvedNow ? "Observed that this matter is resolved."
                        : reopenedNow ? "New source evidence shows this matter is open again."
                        : changedFacts ? "Source information changed." : "Updated the proposed action."
                    tracking.changes.append(CardChange(at: at, runID: observation.runID, message: message))
                    card.updatedAt = at
                    if resolvedNow { summary.resolved += 1 } else { summary.updated += 1 }
                }
                card.tracking = tracking
                workspace.cards[index] = card
                if resolvedNow { cancelQueued(cardID: card.id, at: at, in: &workspace) }
            } else if observation.state != .resolved, let proposal {
                let folder = folderID(in: &workspace)
                var card = MorningCard(folderID: folder, title: proposal.title, sources: [source(for: observation)],
                    rationale: proposal.meaning, action: proposal.action, updatedAt: at)
                card.alternatives = proposal.alternatives.isEmpty ? nil : proposal.alternatives
                card.tracking = CardTracking(sourceID: observation.sourceID,
                    itemKey: observation.itemKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                    sourceName: observation.sourceName, identityEvidence: observation.identityEvidence,
                    firstSeenAt: observation.observedAt, lastSeenAt: observation.observedAt, lastRunID: observation.runID,
                    contentFingerprint: observation.fingerprint, resolutionEvidence: observation.stateEvidence,
                    changes: [CardChange(at: at, runID: observation.runID, message: "Created from collected source information.")])
                workspace.cards.append(card)
                summary.created += 1
            }
        }
        if workspace.cardGenerations == nil { workspace.cardGenerations = [] }
        workspace.cardGenerations?.append(CardGenerationRecord(runIDs: freshRuns.sorted { $0.uuidString < $1.uuidString },
            completedAt: at, created: summary.created, updated: summary.updated, resolved: summary.resolved))
        return summary
    }

    /// Marks every item a step read as judged at its revision, so the next step sends only new or changed ones, and
    /// drops judgments not seen for `CardJudgment.lifetime`.
    static func recordJudgments(_ revisions: [String: String], at: Date, in workspace: inout MorningWorkspace) {
        var judgments = (workspace.judgments ?? [:]).filter { at.timeIntervalSince($0.value.seenAt) <= CardJudgment.lifetime }
        for (key, revision) in revisions { judgments[key] = CardJudgment(revision: revision, seenAt: at) }
        workspace.judgments = judgments
    }

    static func setResolution(cardID: UUID, resolved: Bool, at: Date, in workspace: inout MorningWorkspace) throws {
        guard let index = workspace.cards.firstIndex(where: { $0.id == cardID }) else {
            throw MorningStoreError.invalid("This file could not be found.")
        }
        if var tracking = workspace.cards[index].tracking {
            tracking.resolution = resolved ? .resolved : .open
            tracking.resolvedByUser = resolved
            tracking.resolutionEvidence = resolved ? "Marked handled by you." : "Reopened by you."
            tracking.changes.append(CardChange(at: at, message: tracking.resolutionEvidence))
            workspace.cards[index].tracking = tracking
        } else {
            workspace.cards[index].disposition = resolved ? .resolved : .unreviewed
        }
        workspace.cards[index].updatedAt = at
        if resolved { cancelQueued(cardID: cardID, at: at, in: &workspace) }
    }

    private static func cancelQueued(cardID: UUID, at: Date, in workspace: inout MorningWorkspace) {
        for index in workspace.workItems.indices where workspace.workItems[index].cardID == cardID && workspace.workItems[index].status == .queued {
            workspace.workItems[index].status = .cancelled
            workspace.workItems[index].finishedAt = at
            workspace.workItems[index].progress = "Cancelled because this matter is resolved."
            if workspace.workItems[index].kind == .action,
               let cardIndex = workspace.cards.firstIndex(where: { $0.id == cardID }),
               workspace.cards[cardIndex].disposition == .delegated {
                workspace.cards[cardIndex].disposition = workspace.workItems[index].card.disposition == .mine ? .mine : .unreviewed
            }
        }
    }

    /// The three-part card replaces the older long fields (summary, timing, unknowns), which are no longer shown.
    private static func apply(_ proposal: CardProposal, to card: inout MorningCard) {
        card.title = proposal.title; card.rationale = proposal.meaning
        card.summary = ""; card.timing = ""; card.unknowns = ""
        var action = proposal.action
        action.id = card.action.id
        card.action = action
        // Each option keeps its id by position, so an unchanged proposal isn't logged as a change.
        let previous = card.alternatives ?? []
        let alternatives = proposal.alternatives.enumerated().map { index, option -> MorningAction in
            var option = option
            if index < previous.count { option.id = previous[index].id }
            return option
        }
        card.alternatives = alternatives.isEmpty ? nil : alternatives
    }

    private static func source(for observation: CardObservation, id: UUID = UUID()) -> MorningSource {
        MorningSource(id: id, title: observation.title, kind: observation.kind, excerpt: observation.excerpt,
            url: observation.url, capturedAt: observation.observedAt)
    }

    private static func folderID(in workspace: inout MorningWorkspace) -> UUID {
        if let folder = workspace.folders.first(where: { $0.name.lowercased() == "unfinished" }) { return folder.id }
        if let folder = workspace.folders.first { return folder.id }
        let folder = MorningFolder(name: "Unfinished")
        workspace.folders.append(folder)
        return folder.id
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw MorningStoreError.invalid(message) }
    }
}
