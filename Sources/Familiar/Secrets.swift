import Foundation
import Security

/// Secrets keyed by environment-variable name. Two stores:
/// - `file`: `~/.familiar/secrets.json`, owner-only. Used for dev builds, because a self-signed app is re-identified by
///   macOS on every rebuild and the Keychain prompts each time no matter what the user clicks.
/// - `keychain`: the login Keychain, for builds signed with a trusted (Developer ID) certificate.
enum Secrets {
    enum Store: String { case file, keychain }
    nonisolated(unsafe) static var store: Store = .file
    static let service = "com.isought.familiar"
    static var fileURL: URL { Config.dir.appendingPathComponent("secrets.json") }

    private static func loadFile() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL), let d = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return d
    }

    private static func saveFile(_ d: [String: String]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            try data.write(to: fileURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch { return false }
    }

    /// One-time: copy known keys out of the Keychain into the file store (prompts once, then never again).
    static func migrateKeychainToFile(keys: [String]) {
        guard store == .file, loadFile().isEmpty else { return }
        var d: [String: String] = [:]
        for k in keys {
            if let v = read(k, service: service) ?? legacyServices.lazy.compactMap({ read(k, service: $0) }).first { d[k] = v }
        }
        if !d.isEmpty, saveFile(d) { Log.info("secrets: migrated \(d.keys.sorted()) from the Keychain to \(fileURL.path)") }
    }

    private static let legacyServices = ["com.familiar.app", "com.sidekick.app"]   // pre-rename entries are copied over on first read

    static func get(_ key: String) -> String? {
        if store == .file { let v = loadFile()[key]?.trimmingCharacters(in: .whitespacesAndNewlines); return (v?.isEmpty ?? true) ? nil : v }
        if let v = read(key, service: service) { return v }
        // A dev build may have left the value in the file store; adopt it into the Keychain first (no prompt),
        // and only then look at entries written under older bundle ids (those can prompt once).
        if let v = loadFile()[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty, set(key, v) { return v }
        for legacy in legacyServices {
            if let old = read(key, service: legacy) {
                if set(key, old) { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: legacy, kSecAttrAccount as String: key] as CFDictionary) }
                return old
            }
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
        if store == .file {
            var d = loadFile()
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty { d[key] = nil } else { d[key] = v }
            return saveFile(d)
        }
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
        if store == .file { return loadFile().keys.sorted() }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    static func has(_ key: String) -> Bool { get(key) != nil }
}
