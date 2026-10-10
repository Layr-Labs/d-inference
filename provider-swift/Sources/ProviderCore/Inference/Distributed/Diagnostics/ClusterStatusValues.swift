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
    /// The saved setup's selected generation mode; the pipeline when it names none.
    public let generationMode: ClusterGenerationMode
    public let peers: [Peer]
    public let maximumLifetimeSeconds: Int
    public let maximumRequests: Int

    public struct Peer: Codable, Sendable, Equatable {
        public let id: String
        public let rank: Int
        public let runtimeBinarySHA256: String
        /// What the pinned capability record advertises for this member's
        /// worker. A saved description, not a probe of the installed binary.
        public let supportedGenerationModes: [ClusterGenerationMode]
    }

    init(configuration: ClusterConfiguration, capability: ClusterRuntimeCapability) throws {
        clusterID = configuration.clusterID; memberID = configuration.memberID; role = configuration.role
        configurationSHA256 = ClusterConfigurationCodec.sha256(try ClusterConfigurationCodec.encode(
            configuration, capability: capability, capabilitySHA256: configuration.capabilitySHA256))
        capabilitySHA256 = configuration.capabilitySHA256
        publicModelID = configuration.publicModelID; runtimeModelID = capability.runtimeModelID
        artifactSHA256 = capability.artifactSHA256; configurationModelSHA256 = capability.configurationSHA256
        planSHA256 = configuration.selectedPlanSHA256; prefillSchedule = configuration.selectedPrefillSchedule
        generationMode = configuration.selectedGenerationMode
        maximumLifetimeSeconds = capability.maxLifetimeSeconds; maximumRequests = capability.maxRequests
        peers = configuration.peers.map { .init(id: $0.id, rank: $0.rank, runtimeBinarySHA256: $0.runtimeBinarySHA256,
            supportedGenerationModes: ClusterGenerationSelection.supportedModes(for: $0, capability: capability)) }
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
    /// The mode this leader started its rank with, reported once both ranks
    /// are ready. The owner does not see the follower's mode: the ranks bind
    /// the mode into their own agreement and neither becomes ready on a
    /// different one.
    public let observedGenerationMode: ClusterGenerationMode?
    public let ready: Bool
    public let admission: Admission?
    public let members: [Member]
    public let mtpEnabled: Bool
    public let mtpOffReason: String
    /// How the native ranks found each other. `directNative` is the runtime's
    /// own exchange on the configured link address.
    public let nativeBootstrap: DistributedInstalledBootstrap
    /// False for `directNative`: no owner vouched for the peer that answered.
    public let nativeBootstrapOwnerAuthenticated: Bool
    /// The collective progress limit each native rank was started with.
    public let collectiveProgressLimitMilliseconds: Int

    init(binding: ClusterStatusBinding, phase: String, observedMembershipEpoch: String?,
         observedPrefillSchedule: ClusterPrefillSchedule?, observedGenerationMode: ClusterGenerationMode?,
         ready: Bool, admission: Admission?, members: [Member],
         mtpEnabled: Bool, mtpOffReason: String, nativeBootstrap: DistributedInstalledBootstrap,
         collectiveProgressLimitMilliseconds: Int) {
        self.binding = binding; self.phase = phase; self.observedMembershipEpoch = observedMembershipEpoch
        self.observedPrefillSchedule = observedPrefillSchedule; self.observedGenerationMode = observedGenerationMode
        self.ready = ready; self.admission = admission
        self.members = members; self.mtpEnabled = mtpEnabled; self.mtpOffReason = mtpOffReason
        self.nativeBootstrap = nativeBootstrap; nativeBootstrapOwnerAuthenticated = nativeBootstrap.ownerAuthenticated
        self.collectiveProgressLimitMilliseconds = collectiveProgressLimitMilliseconds
    }

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
