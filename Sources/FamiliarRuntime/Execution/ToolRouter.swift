import Foundation
import FamiliarContracts

/// One capability made available to a run. Namespaced calls never use an unnamespaced route.
package struct ToolRoute {
    package enum Match: Hashable {
        case tool(name: String, toolset: String? = nil)
        case toolset(String)
    }

    package let match: Match
    package let definition: [String: Any]
    fileprivate let handler: ToolExecutor

    package init(match: Match, definition: [String: Any], execute: @escaping ToolExecutor) {
        self.match = match
        self.definition = definition
        self.handler = execute
    }
}

package enum ToolRouterError: LocalizedError, Equatable {
    case emptyRouteName
    case duplicateRoute(name: String, toolset: String?)
    case overlappingToolset(String)
    case mismatchedDefinition(String)

    package var errorDescription: String? {
        switch self {
        case .emptyRouteName:
            return "A tool route must have a nonempty name and namespace."
        case .duplicateRoute(let name, let toolset):
            return "Duplicate tool route: \(toolset.map { "\($0)/" } ?? "")\(name)."
        case .overlappingToolset(let toolset):
            return "Overlapping routes for toolset \(toolset). Register its individual tools or the whole toolset."
        case .mismatchedDefinition(let name):
            return "The definition for tool route \(name) must advertise that same name."
        }
    }
}

/// Immutable dispatch for one run. Only registered capabilities can reach a handler.
/// The caller owns handler lifetime and cancellation once execution has begun.
package final class ToolRouter {
    private struct Key: Hashable {
        let name: String
        let toolset: String?
    }

    package let definitions: [[String: Any]]
    private let exact: [Key: ToolExecutor]
    private let toolsets: [String: ToolExecutor]

    package init(routes: [ToolRoute]) throws {
        var exact: [Key: ToolExecutor] = [:]
        var toolsets: [String: ToolExecutor] = [:]
        for route in routes {
            switch route.match {
            case .tool(let name, let toolset):
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      toolset.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true else {
                    throw ToolRouterError.emptyRouteName
                }
                guard route.definition["name"] as? String == name else {
                    throw ToolRouterError.mismatchedDefinition(name)
                }
                let key = Key(name: name, toolset: toolset)
                guard exact[key] == nil else { throw ToolRouterError.duplicateRoute(name: name, toolset: toolset) }
                if let toolset, toolsets[toolset] != nil { throw ToolRouterError.overlappingToolset(toolset) }
                exact[key] = route.handler
            case .toolset(let toolset):
                guard !toolset.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ToolRouterError.emptyRouteName
                }
                guard toolsets[toolset] == nil, !exact.keys.contains(where: { $0.toolset == toolset }) else {
                    throw ToolRouterError.overlappingToolset(toolset)
                }
                toolsets[toolset] = route.handler
            }
        }
        definitions = routes.map(\.definition)
        self.exact = exact
        self.toolsets = toolsets
    }

    package func accepts(name: String, toolset: String? = nil) -> Bool {
        handler(name: name, toolset: toolset) != nil
    }

    package func execute(_ name: String, _ input: [String: Any], toolset: String? = nil) async -> ToolResult {
        guard !Task.isCancelled else { return .text("Stopped.", isError: true) }
        guard let handler = handler(name: name, toolset: toolset) else {
            return .text("Unknown tool \(name)", isError: true)
        }
        return await handler(name, input, toolset)
    }

    package var executor: ToolExecutor {
        { name, input, toolset in await self.execute(name, input, toolset: toolset) }
    }

    private func handler(name: String, toolset: String?) -> ToolExecutor? {
        if let handler = exact[Key(name: name, toolset: toolset)] { return handler }
        guard let toolset else { return nil }
        return toolsets[toolset]
    }
}
