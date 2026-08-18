import Foundation

enum MyMacIdentitySource: String, Equatable, Sendable {
    case serialNumber = "serial"
    case secureEnclavePublicKey = "se-key"
    case providerSessionID = "provider-id"
}

/// Stable physical-machine identity using the same precedence as the
/// coordinator's `recordIdentity`: serial, then Secure Enclave key, then the
/// provider session identifier as a last-resort legacy fallback.
struct MyMacIdentity: Hashable, Identifiable, Sendable {
    let source: MyMacIdentitySource
    let value: String

    var id: String {
        "\(source.rawValue):\(value)"
    }

    static func resolve(
        serialNumber: String?,
        secureEnclavePublicKey: String?,
        providerSessionID: String
    ) -> MyMacIdentity? {
        if let serialNumber = normalized(serialNumber) {
            return MyMacIdentity(source: .serialNumber, value: serialNumber)
        }
        if let secureEnclavePublicKey = normalized(secureEnclavePublicKey) {
            return MyMacIdentity(
                source: .secureEnclavePublicKey,
                value: secureEnclavePublicKey
            )
        }
        guard let providerSessionID = normalized(providerSessionID) else {
            return nil
        }
        return MyMacIdentity(source: .providerSessionID, value: providerSessionID)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

enum MyMacSensitiveIdentifier {
    /// Returns a glanceable suffix without making the full serial the default
    /// presentation value. The raw value remains available for an explicit
    /// reveal interaction in a future UI.
    static func masked(_ value: String?, visibleSuffixLength: Int = 4) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let suffixLength = max(1, visibleSuffixLength)
        let suffix = normalized.suffix(suffixLength)
        return "•••• \(suffix)"
    }
}
