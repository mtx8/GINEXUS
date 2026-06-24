// Keychain.swift — SP-Connect secret store. MCP credentials (API keys / OAuth tokens) live here,
// NEVER in settings.json and never in logs. Generic-password items under one service; the account
// is the credential reference (e.g. "mcp.notion.token"). Non-syncable (kSecAttrSynchronizable=false)
// so secrets stay on this Mac.
import Foundation
import Security

public enum Keychain {
    private static let service = "com.macktrax.ginexus.secrets"

    @discardableResult
    public static func set(_ value: String, for account: String) -> Bool {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)   // overwrite semantics
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    public static func has(_ account: String) -> Bool { get(account) != nil }

    @discardableResult
    public static func delete(_ account: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let s = SecItemDelete(q as CFDictionary)
        return s == errSecSuccess || s == errSecItemNotFound
    }
}
