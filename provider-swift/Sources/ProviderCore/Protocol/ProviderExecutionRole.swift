import Foundation

/// Restrictive registration role. Omitted legacy role remains ordinary solo.
/// This is neither hardware attestation nor authorization to start native work.
public enum ProviderExecutionRole: String, Codable, Sendable, Equatable {
    case solo = ""
    case clusterMember = "cluster_member"
}

public struct ClusterMemberAccepted: Codable, Sendable, Equatable {
    public let executionRole: ProviderExecutionRole
    public let memberRegistrationNonce: String
    public let providerID: String
    enum CodingKeys: String, CodingKey {
        case executionRole = "execution_role"
        case memberRegistrationNonce = "member_registration_nonce"
        case providerID = "provider_id"
    }
}

/// One connection's negotiation; discarded before every reconnect. The nonce
/// prevents a late prior acknowledgment from opening the new connection.
struct ClusterMemberNegotiation: Sendable {
    let nonce: String
    let deadline: ContinuousClock.Instant
    private(set) var providerID: String?

    init(now: ContinuousClock.Instant = .now) {
        nonce = (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "").lowercased()
        deadline = now.advanced(by: .seconds(10))
    }

    mutating func accept(_ message: ClusterMemberAccepted,
                         now: ContinuousClock.Instant = .now) throws {
        guard providerID == nil, now < deadline,
              message.executionRole == .clusterMember,
              message.memberRegistrationNonce == nonce,
              !message.providerID.isEmpty, message.providerID.utf8.count <= 128 else {
            throw ClusterMemberControlError.negotiationFailed
        }
        providerID = message.providerID
    }
}

public enum ClusterMemberControlError: String, Error, Sendable, LocalizedError {
    case negotiationFailed = "Coordinator did not accept the control-only member role."
    case incompatibleConfiguration = "Control-only member mode cannot own a solo endpoint or engine."
    case connectionEnded = "Cluster member control connection ended."
    public var errorDescription: String? { rawValue }
}
