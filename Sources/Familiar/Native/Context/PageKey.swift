import CoreGraphics
import Foundation

/// Which page this is, steady across visits: its host and path, and only the parts of the address that name the page.
/// Notes, routes and comparisons of two people's walks hang off it, so a page reached by a different link, with a
/// different tracking parameter or inside a different wrapper, is still the same page.
struct PageKey: Hashable, Codable, CustomStringConvertible {
    /// Lowercased, with its port when it has one.
    var host: String
    /// Without a trailing slash, except the root.
    var path: String
    /// Only the parameters that name the page, such as a ServiceNow record's sys_id.
    var query: [String: String] = [:]

    var description: String {
        host + path + (query.isEmpty ? "" : "?" + query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&"))
    }

    /// The key of the page a person is looking at: the main frame inside the page when the page wraps its content in
    /// one (ServiceNow puts every form in a frame), else the page itself.
    static func of(_ documents: [PageDocument]) -> PageKey? {
        guard let top = documents.first else { return nil }
        let main = documents.dropFirst().first { inner in
            guard let outer = top.frame, let frame = inner.frame, outer.width > 0, outer.height > 0,
                  let host = URLComponents(string: inner.url)?.host, let topHost = URLComponents(string: top.url)?.host,
                  sameSite(host, topHost) else { return false }
            let overlap = outer.intersection(frame)
            return !overlap.isNull && overlap.width * overlap.height >= 0.5 * outer.width * outer.height
        }
        return of(main?.url ?? top.url) ?? of(top.url)
    }

    static func of(_ address: String) -> PageKey? {
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""), let rawHost = components.host, !rawHost.isEmpty else {
            return nil
        }
        if let inner = unwrapped(components) { components = inner }
        let host = (components.host ?? rawHost).lowercased() + (components.port.map { ":\($0)" } ?? "")
        var path = components.path.isEmpty ? "/" : components.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let names = identity(host: host, path: path)
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where names.contains(item.name.lowercased()) {
            if let value = item.value, !value.isEmpty, query[item.name.lowercased()] == nil { query[item.name.lowercased()] = value }
        }
        return PageKey(host: host, path: path, query: query)
    }

    /// The page a wrapper address shows: ServiceNow's `nav_to.do?uri=…` and its newer `/now/nav/ui/classic/params/
    /// target/…` both carry the real form's address. Relative addresses take the wrapper's host.
    private static func unwrapped(_ components: URLComponents) -> URLComponents? {
        var inner: String?
        if components.path.lowercased().hasSuffix("/nav_to.do") {
            inner = components.queryItems?.first { $0.name.lowercased() == "uri" }?.value
        } else if let range = components.percentEncodedPath.range(of: "/params/target/", options: .caseInsensitive) {
            inner = String(components.percentEncodedPath[range.upperBound...]).removingPercentEncoding
        }
        guard var target = inner?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else { return nil }
        if !target.lowercased().hasPrefix("http") {
            if !target.hasPrefix("/") { target = "/" + target }
            target = (components.scheme ?? "https") + "://" + (components.host ?? "") + (components.port.map { ":\($0)" } ?? "") + target
        }
        return URLComponents(string: target)
    }

    /// The parameters that name a page on this host. ServiceNow names records and portal pages by parameter; a site
    /// that serves every page from its root, such as a small local app, names them by a page or view parameter.
    /// Anything else, such as tracking or search parameters, is not part of which page it is.
    private static func identity(host: String, path: String) -> Set<String> {
        let name = host.split(separator: ":").first.map(String.init) ?? host
        if name.hasSuffix("service-now.com") || name.hasSuffix("servicenowservices.com") {
            return ["id", "sys_id", "sysparm_id", "table", "sysparm_table"]
        }
        if path == "/" || path.hasSuffix("/index.html") { return ["page", "view", "route", "screen", "tab", "p"] }
        return []
    }

    /// The same site: one host, or one inside the other, as an app's frames on a subdomain are.
    private static func sameSite(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        return a == b || a.hasSuffix("." + b) || b.hasSuffix("." + a)
    }
}
