import Foundation
import DarkbloomClusterProtocol

/// Public identifiers and pins only. Saved setup is separate from a live sample.
public struct ClusterStatusBinding: Codable, Sendable, Equatable {
    public let clusterID: String
    public let memberID: String
    public let role: ClusterConfiguration.Role
    public let configurationSHA256: String
    public let capabilitySHA256: String
    public let publicModelID: String
    public let runtimeModelID: String
    public let artifactSHA256: String
    public let configurationModelSHA256: String
    public let planSHA256: String
    public let prefillSchedule: ClusterPrefillSchedule
    public let peers: [Peer]
    public let maximumLifetimeSeconds: Int
    public let maximumRequests: Int

    public struct Peer: Codable, Sendable, Equatable {
        public let id: String
        public let rank: Int
        public let runtimeBinarySHA256: String
    }

    init(configuration: ClusterConfiguration, capability: ClusterRuntimeCapability) throws {
        clusterID = configuration.clusterID; memberID = configuration.memberID; role = configuration.role
        configurationSHA256 = ClusterConfigurationCodec.sha256(try ClusterConfigurationCodec.encode(
            configuration, capability: capability, capabilitySHA256: configuration.capabilitySHA256))
        capabilitySHA256 = configuration.capabilitySHA256
        publicModelID = configuration.publicModelID; runtimeModelID = capability.runtimeModelID
        artifactSHA256 = capability.artifactSHA256; configurationModelSHA256 = capability.configurationSHA256
        planSHA256 = configuration.selectedPlanSHA256; prefillSchedule = configuration.selectedPrefillSchedule
        maximumLifetimeSeconds = capability.maxLifetimeSeconds; maximumRequests = capability.maxRequests
        peers = configuration.peers.map { .init(id: $0.id, rank: $0.rank, runtimeBinarySHA256: $0.runtimeBinarySHA256) }
    }
}

/// An instant observation, never a readiness lease or authority to recover a
/// journal. No worker uptime, path, prompt, token, credential or environment.
public struct ClusterLiveStatus: Codable, Sendable, Equatable {
    public static let schemaName = "darkbloom_cluster_status_v1"
    public let schema: String
    public let nonce: String
    public let binding: ClusterStatusBinding
    public let authenticationConfigured: Bool
    public let hostPhase: String
    public let session: ClusterSessionObservation
    public let boundPort: UInt16
    public let acquisitions: Int
    public let failed: Bool
    public let ready: Bool
    public let admissionAvailable: Bool
    public let quarantined: Bool
}

public struct ClusterSessionObservation: Codable, Sendable, Equatable {
    public let binding: ClusterStatusBinding
    public let phase: String
    /// Retained only after both actual native Ready values passed pair binding.
    public let observedMembershipEpoch: String?
    public let observedPrefillSchedule: ClusterPrefillSchedule?
    public let ready: Bool
    public let admission: Admission?
    public let members: [Member]
    public let mtpEnabled: Bool
    public let mtpOffReason: String

    public struct Admission: Codable, Sendable, Equatable {
        /// The leader's already-clamped local lifetime, sampled locally.
        public let remainingLifetimeNanoseconds: UInt64
        public let remainingRequests: Int
        public let activeRequest: Bool
        public let draining: Bool
        public let valid: Bool
    }
    public struct Member: Codable, Sendable, Equatable {
        public enum Transport: String, Codable, Sendable { case localPipes, authenticatedSSH }
        public let peerID: String
        public let rank: Int
        public let transport: Transport
        public let nativeReady: Bool
        public let requestCapacityBytes: Int?
        public let nativeCleanupObserved: Bool
        public let ownerReleaseAcknowledged: Bool
        public let ownerTermination: Termination?
    }
    public struct Termination: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case launchFailed, exited, signalled }
        public let kind: Kind
        public let status: Int32?
    }
}
