import Foundation
import FamiliarContracts
import FamiliarRuntime

/// Assembles the tools available to one request. GUI and headless callers share
/// the same dispatch; native implementations stay on the app side of the boundary.
@MainActor
enum ExecutionTools {
    enum Policy { case standard, calendarRead, sourceRead, sourceFollowUp }

    static func make(registry: ToolRegistry, context: ScreenContext?,
                     control: ComputerController?, background: Bool,
                     policy: Policy = .standard, additionalRoutes: [ToolRoute] = [],
                     trackedItems: [TrackedSourceItem] = [],
                     onObservation: (() -> Void)? = nil, onNavigation: (() -> Void)? = nil,
                     lookAtScreen: @escaping () async -> ToolResult) throws -> ToolRouter {
        if policy != .standard {
            guard background, let control else {
                throw ClaudeError(message: "Source collection needs a selected background task window.")
            }
            return try collectionTools(control: control, policy: policy, additionalRoutes: additionalRoutes,
                                     trackedItems: Array(trackedItems.prefix(ReadingSubmission.trackedItemLimit)), onObservation: onObservation, onNavigation: onNavigation)
        }
        var routes: [ToolRoute] = []
        let selection = registry.select(for: context)
        let runner = registry.runner
        for pack in selection.active + selection.global {
            for script in pack.scripts {
                let requirements = pack.requires
                routes.append(ToolRoute(match: .tool(name: script.id), definition: script.definition) { _, input, _ in
                    do { return .text(try await runner.run(script, args: input, context: context, secrets: requirements)) }
                    catch { return .text(error.localizedDescription, isError: true) }
                })
            }
        }

        let root = registry.root
        for definition in BuiltinTools.definitions(background: background && control != nil) {
            guard let name = definition["name"] as? String else { continue }
            routes.append(ToolRoute(match: .tool(name: name), definition: definition) { _, input, _ in
                if background, let control {
                    if name == "look_at_screen" { return await control.lookAtTargetScreen() }
                    if name == "read_screen" { return control.readTargetScreen() }
                }
                if name == "look_at_screen" { return await lookAtScreen() }
                if name == "read_screen" { return await ScreenText.readFrontmost() }
                return BuiltinTools.execute(name, input, root: root)
            })
        }

        if let control {
            routes.append(ToolRoute(match: .tool(name: "find_on_screen"), definition: ComputerController.findDefinition) { _, input, _ in
                control.find(input["query"] as? String ?? "")
            })
            routes.append(ToolRoute(match: .toolset("computer"), definition: ComputerController.toolsetDefinition) { name, input, _ in
                await control.perform(name, input)
            })
            if background {
                for definition in ComputerController.backgroundDefinitions {
                    guard let name = definition["name"] as? String else { continue }
                    routes.append(ToolRoute(match: .tool(name: name), definition: definition) { _, input, _ in
                        switch name {
                        case "target_window": return await control.targetWindow(input)
                        case "click_element": return await control.clickElement(input)
                        case "send_message": return await control.sendMessage(input)
                        case "ask_for_the_mouse": return await control.askForMouse(input)
                        case "give_the_mouse_back": return control.giveMouseBack()
                        default: return .text("Unknown tool \(name)", isError: true)
                        }
                    })
                }
            }
        }
        return try ToolRouter(routes: routes + additionalRoutes)
    }

    /// Source collection uses native observations and a deliberately small navigation surface.
    /// No pack script, file tool, arbitrary computer input, send, typing or key route is available.
    private static func collectionTools(control: ComputerController, policy: Policy, additionalRoutes: [ToolRoute],
                                      trackedItems: [TrackedSourceItem], onObservation: (() -> Void)?, onNavigation: (() -> Void)?) throws -> ToolRouter {
        let calendar = policy == .calendarRead
        if calendar { control.pressRefusal = CalendarNavigationPolicy.refusal }
        else if policy == .sourceFollowUp {
            control.pressRefusal = { ReadingNavigationPolicy.followUpRefusal($0, trackedItems: trackedItems) }
        } else { control.pressRefusal = ReadingNavigationPolicy.refusal }
        var routes = additionalRoutes
        for definition in BuiltinTools.definitions(background: true) {
            guard let name = definition["name"] as? String,
                  ["look_at_screen", "read_screen"].contains(name) else { continue }
            routes.append(ToolRoute(match: .tool(name: name), definition: definition) { _, _, _ in
                let result: ToolResult
                if name == "read_screen" { result = control.readTargetScreen() }
                else { result = await control.lookAtTargetScreen() }
                if !result.isError { onObservation?() }
                return result
            })
        }
        var target = ComputerController.targetWindowDefinition
        target["description"] = "List task windows, or explicitly select the demonstrated source application by its id. No window is selected initially. Verify the saved location and account with a fresh read after selecting; do not switch accounts or infer a target from the foreground window."
        routes.append(ToolRoute(match: .tool(name: "target_window"), definition: target) { _, input, _ in
            if input["select"] != nil { onNavigation?() }
            return await control.targetWindow(input)
        })
        routes.append(ToolRoute(match: .tool(name: "find_on_screen"), definition: ComputerController.findDefinition) { _, input, _ in
            control.find(input["query"] as? String ?? "")
        })
        var click = ComputerController.clickElementDefinition
        click["description"] = calendar
            ? "Press a calendar navigation control or event cell from the latest find_on_screen result. The actual Accessibility control is checked before pressing. Editing, RSVP and unrecognized controls are refused. Do not retry with coordinates or keys; report the unsupported navigation as a collection limitation."
            : "Press a recognized mailbox tab or page-navigation button from the latest find_on_screen result. The actual Accessibility control is checked before pressing. Message rows, cells, links, compose/reply controls, selection toggles and unrecognized controls are refused. Read the mailbox list without opening messages or following message links; report unsupported navigation as incomplete coverage."
        if policy == .sourceFollowUp {
            click["description"] = "Press recognized mailbox navigation or a message row/cell matching one of the specifically tracked follow-ups. Opening that tracked thread may mark it read, which the user authorized. Unrelated message rows, content links, compose/reply controls, selection toggles and mutations are refused. Verify matching identity and account before opening; bound follow-up navigation to ten page/scroll actions and report unresolved coverage if not found."
        }
        routes.append(ToolRoute(match: .tool(name: "click_element"), definition: click) { _, input, _ in
            onNavigation?()
            return await control.clickElement(input)
        })
        let scrollName = calendar ? "calendar_scroll" : "reading_scroll"
        let scroll: [String: Any] = [
            "name": scrollName,
            "description": "Scroll the selected source window to inspect additional visible records. Take a fresh read afterward. This does not borrow the physical mouse; unsupported background scrolling must be reported as a limitation.",
            "input_schema": ["type": "object", "properties": [
                "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                "amount": ["type": "integer", "minimum": 1, "maximum": 10],
                "coordinate": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2],
            ], "required": ["direction"], "additionalProperties": false],
        ]
        routes.append(ToolRoute(match: .tool(name: scrollName), definition: scroll) { _, input, _ in
            guard let direction = input["direction"] as? String, ["up", "down", "left", "right"].contains(direction) else {
                return .text("Choose up, down, left or right.", isError: true)
            }
            var native: [String: Any] = ["scroll_direction": direction,
                                       "scroll_amount": max(1, min(10, (input["amount"] as? NSNumber)?.intValue ?? 3))]
            if let coordinate = input["coordinate"] { native["coordinate"] = coordinate }
            onNavigation?()
            return await control.perform("scroll", native)
        })
        return try ToolRouter(routes: routes)
    }
}

/// Conservative navigation checks over live AX metadata, not labels supplied by the model.
/// Unrecognized/custom calendar controls remain unsupported rather than falling back to raw input.
enum CalendarNavigationPolicy {
    static func refusal(_ info: IrreversibleGuard.ElementInfo) -> String? {
        let metadata = [info.title, info.description, info.domID].compactMap { $0 }.joined(separator: " ")
            .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let metadataWords = Set(metadata.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let editing: Set<String> = ["new", "create", "add", "edit", "save", "send", "submit", "delete", "remove", "cancel",
                                    "accept", "decline", "tentative", "rsvp", "respond", "response", "reply", "forward", "join",
                                    "share", "publish", "book", "schedule", "reschedule", "move", "duplicate", "update", "apply"]
        guard metadataWords.isDisjoint(with: editing), !info.isSecure, !info.isDefaultButton else { return blocked }
        guard case .safe = IrreversibleGuard.classifyPress(info, inSheet: false, declared: [], warningNoteLabels: []) else { return blocked }
        let label = info.label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = Set(label.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let roles: Set<String> = ["AXButton", "AXRadioButton", "AXTab", "AXCell", "AXRow", "AXLink"]
        guard let role = info.role, roles.contains(role), !label.isEmpty else { return blocked }
        if ["AXCell", "AXRow"].contains(role) { return nil }
        let navigation: Set<String> = ["calendar", "calendars", "today", "tomorrow", "yesterday", "next", "previous", "back",
                                       "day", "week", "month", "year", "agenda", "work", "view", "list", "close", "details", "go", "to", "the", "show",
                                       "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                                       "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
                                       "mon", "tue", "wed", "thu", "fri", "sat", "sun", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        // A time-bearing label is a common way calendars expose an event button.
        let hasTime = label.range(of: #"\b\d{1,2}:\d{2}\b"#, options: .regularExpression) != nil
        let onlyDay = Int(label).map { (1...31).contains($0) } ?? false
        let onlyNavigation = words.allSatisfy { navigation.contains($0) || Int($0) != nil }
        if hasTime || onlyDay || (onlyNavigation && !words.isDisjoint(with: navigation)) { return nil }
        return blocked
    }

    static let blocked = "This control is not supported for calendar reading. Only recognized calendar navigation and event cells can be pressed; editing and RSVP controls are unavailable. Report incomplete coverage if you cannot continue."
}
