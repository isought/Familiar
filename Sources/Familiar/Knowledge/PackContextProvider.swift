import Foundation

/// The packs and scene notes used to assemble one request. Each request gets a fresh selection from the registry.
struct PackContext {
    let active: [ToolPack]
    let global: [ToolPack]
    let others: [ToolPack]
    let sceneNotes: [StickyNote]
    let missingRequirements: [(pack: ToolPack, keys: [String])]
    let promptSection: String
}

/// Builds the existing tool-pack context without owning a conversation, capture, or recording.
enum PackContextProvider {
    /// `includeNotes` lets a pen request place target notes separately. The headless path can omit setup notices
    /// with `includeMissingRequirements`; tests supply the lookup so no real credentials are inspected.
    @MainActor
    static func context(
        for scene: ScreenContext?,
        registry: ToolRegistry,
        docsLimit: Int,
        includeNotes: Bool = true,
        includeMissingRequirements: Bool = true,
        missingRequirements: (([ToolPack]) -> [(pack: ToolPack, keys: [String])])? = nil
    ) -> PackContext {
        let selection = registry.select(for: scene)
        let notes = registry.notes(for: scene)
        let missing: [(pack: ToolPack, keys: [String])]
        if includeMissingRequirements {
            let selected = selection.active + selection.global
            missing = missingRequirements?(selected) ?? registry.missingRequirements(for: selected)
        } else {
            missing = []
        }
        let prompt = promptSection(active: selection.active, global: selection.global, others: selection.others,
                                   notes: includeNotes ? notes : [], missingRequirements: missing, docsLimit: docsLimit)
        return PackContext(active: selection.active, global: selection.global, others: selection.others,
                           sceneNotes: notes, missingRequirements: missing, promptSection: prompt)
    }

    /// Formatting uses the supplied values only; availability checks and scene selection happen above.
    static func promptSection(
        active: [ToolPack],
        global: [ToolPack],
        others: [ToolPack],
        notes: [StickyNote],
        missingRequirements: [(pack: ToolPack, keys: [String])],
        docsLimit: Int
    ) -> String {
        var section = Prompt.toolPacks(active: active, global: global, others: others, stuffLimit: docsLimit)
        section += Prompt.notes(onTarget: [], elsewhere: notes)
        if !missingRequirements.isEmpty {
            section += "\n## Not configured yet\n"
            for missing in missingRequirements {
                section += "- \(missing.pack.name) needs \(missing.keys.joined(separator: ", ")). Its scripts will fail until the user adds it in Noteling Settings (right-click the bubble → Settings…).\n"
            }
        }
        return section
    }
}
