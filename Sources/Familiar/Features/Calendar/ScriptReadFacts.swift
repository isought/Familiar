import Foundation

/// The mail facts a script read returns for one message, kept as data beside the text the card step reads, so what
/// arrived can be counted and sorted later without parsing that text back. Only what the row says is kept: a flag
/// the script left out stays nil rather than being guessed.
struct MailFacts: Codable, Equatable {
    /// The From header as the script returned it.
    var from = ""
    var name: String? = nil
    var address: String? = nil
    var domain: String? = nil
    /// The script's own ISO-8601 text, kept as is.
    var received: String? = nil
    var unread: Bool? = nil
    var starred: Bool? = nil
    var tab: String? = nil
    var important: Bool? = nil
    var bulk: Bool? = nil
}

extension MailFacts {
    /// Nil for a row that brings its own `text`, or that has none of the mail fields.
    init?(row: [String: Any]) {
        guard Self.text(row["text"]) == nil else { return nil }
        let from = Self.text(row["from"]), received = Self.text(row["received"]), tab = Self.text(row["tab"])
        let flags = ["unread", "starred", "important", "bulk"].map { row[$0] as? Bool }
        guard from != nil || received != nil || tab != nil || flags.contains(where: { $0 != nil }) else { return nil }
        let sender = from.map(Self.sender) ?? (name: nil, address: nil)
        self.init(from: from ?? "", name: sender.name, address: sender.address,
                  domain: sender.address?.split(separator: "@").last.map(String.init),
                  received: received, unread: flags[0], starred: flags[1], tab: tab?.lowercased(), important: flags[2], bulk: flags[3])
    }

    /// `Name <a@b>` (quotes around the name dropped), a bare address, or a bare name.
    private static func sender(_ header: String) -> (name: String?, address: String?) {
        if header.hasSuffix(">"), let open = header.lastIndex(of: "<") {
            return (text(header[..<open].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))),
                    address(String(header[open...].dropFirst().dropLast())))
        }
        if !header.contains(where: \.isWhitespace), let address = address(header) { return (nil, address) }
        return (header, nil)
    }

    /// Lowercased, and only when there is something on both sides of its last `@`.
    private static func address(_ value: String) -> String? {
        let address = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard let at = address.lastIndex(of: "@"), at > address.startIndex, address.index(after: at) < address.endIndex else { return nil }
        return address
    }

    private static func text(_ value: Any?) -> String? {
        let text = (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// What a script read says about the whole mailbox rather than the items it returned: how many messages arrived,
/// how many came back, whether the list was cut off, and the time it read from.
struct ScriptReadCounts: Codable, Equatable {
    var arrived: Int
    var returned: Int
    var truncated: Bool
    var since: Date? = nil
}
