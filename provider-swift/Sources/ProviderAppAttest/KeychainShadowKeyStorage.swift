import CryptoKit
import Foundation
import Security

/// Only the key identifier/lifecycle state is stored here. The private key stays in Apple's service.
public struct KeychainShadowKeyStorage: ShadowKeyStorage {
    public init() {}

    private func query(_ scope: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "io.darkbloom.provider.app-attest.shadow.v1",
         kSecAttrAccount as String: Data(SHA256.hash(data: Data(scope.utf8))).base64EncodedString()]
    }

    public func load(scope: String) throws -> ShadowKeyRecord? {
        var query = query(scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data,
              let record = try? JSONDecoder().decode(ShadowKeyRecord.self, from: data)
        else { throw ShadowFailure.keychainError }
        return record
    }

    public func save(_ record: ShadowKeyRecord, scope: String) throws {
        let data = try JSONEncoder().encode(record)
        let query = query(scope)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrSynchronizable as String] = false
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ShadowFailure.keychainError }
    }
}
