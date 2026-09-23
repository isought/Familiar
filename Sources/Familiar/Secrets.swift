import Foundation
import Security

/// Secrets live in the login Keychain under one service, keyed by environment-variable name.
enum Secrets {
    static let service = "com.familiar.app"

    private static let legacyService = "com.sidekick.app"   // pre-rename entries are copied over on first read

    static func get(_ key: String) -> String? {
        if let v = read(key, service: service) { return v }
        if let old = read(key, service: legacyService) {
            if set(key, old) { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: legacyService, kSecAttrAccount as String: key] as CFDictionary) }
            return old
        }
        return nil
    }

    private static func read(_ key: String, service: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Empty value deletes the item.
    @discardableResult
    static func set(_ key: String, _ value: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty {
            let st = SecItemDelete(base as CFDictionary)
            return st == errSecSuccess || st == errSecItemNotFound
        }
        let data = Data(v.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Familiar: \(key)"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func keys() -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    static func has(_ key: String) -> Bool { get(key) != nil }
}
