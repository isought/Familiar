import Foundation
import FamiliarContracts
import FamiliarRuntime

/// Assembles the tools available to one request. GUI and headless callers share
/// the same dispatch; native implementations stay on the app side of the boundary.
@MainActor
enum ExecutionTools {
    static func make(registry: ToolRegistry, context: ScreenContext?,
                     control: ComputerController?, background: Bool,
                     lookAtScreen: @escaping () async -> ToolResult) throws -> ToolRouter {
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
        for definition in BuiltinTools.definitions {
            guard let name = definition["name"] as? String else { continue }
            routes.append(ToolRoute(match: .tool(name: name), definition: definition) { _, input, _ in
                if name == "look_at_screen" { return await lookAtScreen() }
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
                        case "ask_for_the_mouse": return await control.askForMouse(input)
                        case "give_the_mouse_back": return control.giveMouseBack()
                        default: return .text("Unknown tool \(name)", isError: true)
                        }
                    })
                }
            }
        }
        return try ToolRouter(routes: routes)
    }
}
