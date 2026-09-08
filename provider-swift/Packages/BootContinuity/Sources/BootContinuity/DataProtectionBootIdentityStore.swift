import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct DataProtectionBootIdentityStore: BootIdentityStore {
    static let accessGroup = "SLDQ2GJ6TL.io.darkbloom.provider"
    static let service = "io.darkbloom.provider.boot-continuity.v1"

    func read(context: BootContinuityContext) throws -> Data? {
        var query = Self.baseQuery(context: context)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw BootCustodyError.keychainFailure(status) }
        guard let data = value as? Data, data.count <= BootKeyRecord.maximumSize else {
            throw BootContinuityError.invalidRecord
        }
        return data
    }

    func insert(_ data: Data, context: BootContinuityContext) throws {
        guard data.count <= BootKeyRecord.maximumSize else { throw BootContinuityError.invalidRecord }
        var query = Self.baseQuery(context: context)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { throw BootCustodyError.recordAlreadyExists }
        guard status == errSecSuccess else { throw BootCustodyError.keychainFailure(status) }
    }

    static func baseQuery(context: BootContinuityContext) -> [String: Any] {
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountLocator(context: context),
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationContext as String: authentication,
        ]
    }

    static func accountLocator(context: BootContinuityContext) -> String {
        var data = Data("darkbloom/boot-custody-location/v1\0".utf8)
        for value in [context.accountID, context.deviceID, context.coordinatorOrigin, context.releaseID] {
            let bytes = Data(value.utf8)
            var count = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        var generation = context.policyGeneration.bigEndian
        withUnsafeBytes(of: &generation) { data.append(contentsOf: $0) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
