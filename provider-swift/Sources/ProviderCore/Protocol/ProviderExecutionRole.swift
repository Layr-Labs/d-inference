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
    /// How long one connection's acceptance may take after its registration.
    static let window: Duration = .seconds(10)

    let nonce: String
    let deadline: ContinuousClock.Instant
    private(set) var providerID: String?

    init(now: ContinuousClock.Instant = .now) {
        nonce = (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "").lowercased()
        deadline = now.advanced(by: Self.window)
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
    /// Not a refusal: no attempt during the wait reached a coordinator.
    case coordinatorUnreachable = "The coordinator could not be reached before this member's registration wait ended, so nothing accepted or refused its role; start it again once the coordinator is reachable."
    /// Not a refusal either: the coordinator answered the registration as an
    /// ordinary provider's and kept the connection open past the negotiation
    /// window without acknowledging the role, which a coordinator that knows
    /// the role never does (it acknowledges or closes the connection). A
    /// coordinator that predates the role answers this way.
    case roleUnsupported = "The coordinator does not support the cluster member role (it answered this registration as an ordinary provider's and never acknowledged the role)."
    case incompatibleConfiguration = "Control-only member mode cannot own a solo endpoint or engine."
    case connectionEnded = "Cluster member control connection ended."
    case invalidMembership = "Cluster membership claim is malformed."
    public var errorDescription: String? { rawValue }
}
