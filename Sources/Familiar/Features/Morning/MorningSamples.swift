import Foundation

/// Explicitly requested, fictional examples. Nothing here claims to have read a connected account.
enum MorningSamples {
    static func append(to workspace: inout MorningWorkspace) {
        guard !workspace.samplesLoaded else { return }
        func folder(_ name: String) -> UUID {
            if let existing = workspace.folders.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return existing.id }
            let new = MorningFolder(name: name)
            workspace.folders.append(new)
            return new.id
        }
        let replies = folder("Replies"), unfinished = folder("Unfinished"), housekeeping = folder("Housekeeping")
        // New IDs keep fictional people separate from real contacts, even if their names happen to match.
        let maya = MorningPerson(name: "Maya Chen", role: "Launch sponsor · example", relationship: "Skip-level manager · example", context: "Fictional example: Maya sponsors Atlas. You own the readiness review; Jordan owns onboarding design.", identities: ["maya@example.com"])
        let alex = MorningPerson(name: "Alex Rivera", role: "Customer rollout lead · example", relationship: "Customer at Northstar · example", context: "Fictional example: Alex plans Northstar’s rollout. You are his contact for delivery dates.", identities: ["alex@example.com"])
        let jordan = MorningPerson(name: "Jordan Lee", role: "Product designer · example", relationship: "Teammate on Atlas · example", context: "Fictional example: Jordan designs onboarding. You review the edge cases together.", identities: ["jordan@example.com", "Jira: jordan-example"])
        workspace.people.append(contentsOf: [maya, alex, jordan])
        let sampleDate = Date()
        func source(_ title: String, kind: String, _ excerpt: String) -> MorningSource {
            MorningSource(title: title, kind: "\(kind) · fictional sample", excerpt: excerpt, capturedAt: sampleDate)
        }
        func localContext(_ title: String, _ instruction: String) -> MorningAction {
            MorningAction(title: title, instruction: "Using only the fictional evidence attached to this sample file, \(instruction) Do not access real apps or claim to have fetched new information.")
        }
        workspace.cards.append(contentsOf: [
            MorningCard(folderID: replies, title: "Launch position by 11.", summary: "Maya wants the remaining risks and their owners before her review.", personIDs: [maya.id, jordan.id], sources: [
                source("Maya’s readiness request", kind: "Outlook", "Can you confirm by 11 whether Atlas is ready for Friday? Please include the two remaining risks and who owns them. I’m taking the update into the readiness review."),
                source("ATL-142 and your checklist", kind: "Jira + personal note", "ATL-142 is awaiting QA sign-off. Your checklist names Jordan for onboarding edge cases. The QA completion time is not recorded.")
            ], rationale: "The sample request has a stated deadline, and you own the readiness review. Maya is the launch sponsor.", action: MorningAction(title: "Prepare update", instruction: "Draft a status update from this fictional evidence, including the open risks and known owners. Keep QA timing explicitly unconfirmed. Return the draft for review; do not send it."), contextAction: localContext("List missing details", "identify the questions needed to establish QA timing and ownership."), unknowns: "The QA completion time is missing.", timing: "Sample deadline: 11:00", isSample: true),
            MorningCard(folderID: replies, title: "Confirm Northstar’s date.", summary: "Alex’s rollout depends on the delivery date you promised to check.", personIDs: [alex.id], sources: [
                source("Alex’s rollout question", kind: "Outlook", "Any update on the delivery date? We need to schedule our rollout team for next week. Your earlier reply: I’ll check with delivery and get you an update on Monday."),
                source("DEL-38 target date", kind: "Jira", "Delivery targets Tuesday. The date is not confirmed.")
            ], rationale: "In this example you promised Alex an update. His rollout planning depends on the response.", action: MorningAction(title: "Draft reply", instruction: "Prepare a reply to the fictional customer acknowledging the promised update. Explain that Tuesday is a target, not a confirmed date. Return the draft; do not send it."), contextAction: localContext("Prepare follow-up questions", "list what to ask the delivery owner before confirming a date."), unknowns: "Delivery has not confirmed the date.", timing: "Sample commitment: today", isSample: true),
            MorningCard(folderID: unfinished, title: "Onboarding review.", summary: "Jordan needs your feedback on two edge cases carried over from yesterday.", personIDs: [jordan.id], sources: [
                source("ATL-142 review request", kind: "Jira", "Ready for your review: returning users and expired invitations. Please leave feedback on these two flows."),
                source("Your unfinished review note", kind: "Personal note", "Review the onboarding edge cases with Jordan before Friday.")
            ], rationale: "The sample note and ticket refer to the same unfinished review. Jordan is waiting for feedback.", action: MorningAction(title: "Prepare checklist", instruction: "Turn returning users and expired invitations into a review checklist using the fictional source notes. Mark assumptions and missing design evidence. Do not approve the design or change any ticket."), contextAction: localContext("List evidence to collect", "list the design evidence that would help review the two flows."), unknowns: "Design screenshots and acceptance criteria are not attached.", timing: "Sample timing: before Friday’s review", isSample: true),
            MorningCard(folderID: unfinished, title: "Capture rollout questions.", summary: "An unfinished note has questions about migration and training.", sources: [
                source("Rollout questions", kind: "Personal note", "Before rollout: what moves automatically? Who trains the support team?")
            ], rationale: "The sample note contains two unanswered questions. No owner or deadline is recorded.", action: MorningAction(title: "Organize questions", instruction: "Organize the fictional note into a short local checklist. Preserve the unknown rollout identity, owner and deadline. Do not share it."), contextAction: localContext("Clarify what is missing", "identify the minimum questions needed to make this note actionable."), unknowns: "The note does not say which rollout this refers to.", timing: "No deadline recorded", isSample: true),
            MorningCard(folderID: housekeeping, title: "A home for build digests.", summary: "Three fictional automated summaries could fit a narrow inbox rule.", sources: [
                source("Three matching build summaries", kind: "Outlook", "All three sample emails are from build-digest@example.com with subject Daily build summary — Atlas. Each says: Builds passed. No failures reported.")
            ], rationale: "These sample summaries repeat the same passing build information. A narrow rule could keep them accessible outside the main inbox.", action: MorningAction(title: "Prepare rule", instruction: "Prepare a proposed Outlook rule from the fictional messages: exact sender build-digest@example.com and subjects starting Daily build summary, moved to Build digests. Explain the matching conditions and possible exceptions. Return only the proposal; do not create a rule or move any messages."), contextAction: localContext("Review matching evidence", "explain which attached messages match the proposal and what evidence is missing before it should be applied."), unknowns: "Real inbox contents and existing rules have not been checked.", timing: "No deadline", isSample: true)
        ])
        workspace.samplesLoaded = true
    }
}
