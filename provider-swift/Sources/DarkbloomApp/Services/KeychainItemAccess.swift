import CoreFoundation
import Foundation
import Security

/// Narrow Security.framework seam used by the app session store.
///
/// Production calls the real SecItem functions. Tests can inject OSStatus // pragma: allowlist secret
/// outcomes without replacing the higher-level session manager, preserving the
/// exact partition/fallback behavior under test.
struct KeychainItemAccess: @unchecked Sendable {
    var copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    var update: (CFDictionary, CFDictionary) -> OSStatus
    var delete: (CFDictionary) -> OSStatus

    static let live = KeychainItemAccess(
        copyMatching: SecItemCopyMatching,
        add: SecItemAdd,
        update: SecItemUpdate,
        delete: SecItemDelete
    )
}

enum KeychainSessionStoreError: LocalizedError, Equatable {
    case clearFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .clearFailed(let status):
            let detail = SecCopyErrorMessageString(status, nil).map {
                $0 as String
            }
            return "Darkbloom could not clear the saved account session"
                + " (Keychain \(status)"
                + (detail.map { ": \($0)" } ?? "")
                + ")."
        }
    }
}
