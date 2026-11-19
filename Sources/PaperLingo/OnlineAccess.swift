import Foundation
import PaperCore
import Security

/// The non-synchronizing login keychain item is scoped to this app. No key is kept in preferences.
enum OnlineAccess {
    private static var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "local.paperlingo.mac") + ".openai",
         kSecAttrAccount as String: "api-key",
         kSecAttrSynchronizable as String: false]
    }

    static func hasKey() throws -> Bool {
        var query = item
        query[kSecReturnAttributes as String] = true
        var attributes: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &attributes)
        if result == errSecItemNotFound { return false }
        try check(result)
        return true
    }

    static func save(_ input: String) throws {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), key.utf8.count <= 1024,
              key.utf8.count > 12, key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw AppError.message("请粘贴完整的 OpenAI API Key，检查是否包含空格或换行。")
        }
        let bytes = Data(key.utf8)
        let result = SecItemUpdate(item as CFDictionary, [kSecValueData: bytes] as CFDictionary)
        if result == errSecItemNotFound {
            var entry = item
            entry[kSecAttrLabel as String] = "PaperLingo · OpenAI API Key"
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            entry[kSecValueData as String] = bytes
            try check(SecItemAdd(entry as CFDictionary, nil))
        } else {
            try check(result)
        }
    }

    static func remove() throws {
        let result = SecItemDelete(item as CFDictionary)
        if result != errSecItemNotFound { try check(result) }
    }

    static func client() throws -> OpenAIClient {
        var query = item
        query[kSecReturnData as String] = true
        var value: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &value)
        if result == errSecItemNotFound { throw AppError.message("请先在「设置 → 模型服务」保存 OpenAI API Key。") }
        try check(result)
        guard let bytes = value as? Data, let key = String(data: bytes, encoding: .utf8), !key.isEmpty else {
            throw AppError.message("无法读取已保存的密钥，请在设置中重新保存。")
        }
        return OpenAIClient(apiKey: key)
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw AppError.message("无法访问 macOS 钥匙串（\(status)）。请解锁登录钥匙串并允许 PaperLingo 访问。")
        }
    }
}
