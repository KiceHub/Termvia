import Foundation
import Security

/// The standard macOS keychain supports the app's ad-hoc distribution. Data
/// Protection access groups would require a signed provisioning profile.
public struct KeychainSecretStore: EnumerableCredentialSecretStore {
    private let service: String

    public init(service: String) { self.service = service }

    private var items: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    private func item(_ id: UUID) -> [String: Any] {
        var query = items
        query[kSecAttrAccount as String] = id.uuidString
        return query
    }

    public func identifiers() throws -> [UUID] {
        var query = items
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status)
        guard let attributes = result as? [[String: Any]] else { throw SSHError.invalid(T("无法验证迁移后的登录信息")) }
        return attributes.compactMap { attributes in
            (attributes[kSecAttrAccount as String] as? String).flatMap(UUID.init(uuidString:))
        }
    }

    public func read(_ id: UUID) throws -> String? {
        var query = item(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SSHError.invalid(T("无法验证迁移后的登录信息"))
        }
        try validateLoginSecret(value)
        return value
    }

    public func write(_ value: String, id: UUID) throws {
        try validateLoginSecret(value)
        let query = item(id)
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        var attributes = query
        attributes[kSecAttrLabel as String] = "Termvia"
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try check(SecItemUpdate(query as CFDictionary, update as CFDictionary))
        } else {
            try check(status)
        }
    }

    public func delete(_ id: UUID) throws {
        let status = SecItemDelete(item(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? String(status)
        throw SSHError.invalid(T("无法访问 macOS 钥匙串：%@", message))
    }
}
