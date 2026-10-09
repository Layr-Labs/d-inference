import Foundation
import DarkbloomClusterProtocol

/// Who this Mac is paired with, as the saved setup names it. Labels, ranks,
/// digests and fingerprints only: no host name, user name, address or path.
public struct ClusterConsolePairing: Encodable, Sendable, Equatable {
    public struct PairApproval: Encodable, Sendable, Equatable {
        public let id: String
        public let model: String
        public let generation: UInt64
        public let notAfter: String
        public let allowedChips: [String]
    }
    public let clusterID: String
    public let memberID: String
    public let role: ClusterConfiguration.Role
    public let localRank: Int
    public let peerID: String
    public let peerRank: Int
    /// The RDMA device the setup assigns to this Mac.
    public let linkDevice: String
    public let trust: ClusterConsoleTrust
    /// A saved coordinator approval entry. It is an expectation this Mac
    /// registers with, never a grant: only the coordinator's own file approves.
    public let pairApproval: PairApproval?
}

extension ClusterConsolePairing {
    /// Reads the labels from the setup and looks at its trust files as they are now.
    init(configuration: ClusterConfiguration) {
        let local = configuration.peers[configuration.localRank], peer = configuration.peers[1 - configuration.localRank]
        self.init(clusterID: configuration.clusterID, memberID: configuration.memberID, role: configuration.role,
            localRank: local.rank, peerID: peer.id, peerRank: peer.rank, linkDevice: local.jacclDevice,
            trust: .observe(configuration.trust),
            pairApproval: configuration.nativeMember.map {
                .init(id: $0.approval.id, model: $0.approval.model, generation: $0.approval.generation,
                    notAfter: $0.approval.notAfter, allowedChips: $0.approval.allowedChips)
            })
    }
}

/// The model the saved setup serves and how its layers are divided.
public struct ClusterConsoleSavedModel: Encodable, Sendable, Equatable {
    public struct Stage: Encodable, Sendable, Equatable {
        public let rank: Int
        public let peerID: String
        public let local: Bool
        public let sourceLayerStart: Int
        public let sourceLayerEnd: Int
    }
    public let publicModelID: String
    public let runtimeModelID: String
    public let adapterID: String
    public let artifactSHA256: String
    public let planSHA256: String
    public let prefillSchedule: String
    public let stages: [Stage]
    public let maximumLifetimeSeconds: Int
    public let maximumRequests: Int
    public let maximumPromptTokens: Int
    public let maximumOutputTokens: Int
}

extension ClusterConsoleSavedModel {
    init(configuration: ClusterConfiguration, capability: ClusterRuntimeCapability) throws {
        let partition = try capability.selection(planSHA256: configuration.selectedPlanSHA256)
        self.init(publicModelID: configuration.publicModelID, runtimeModelID: capability.runtimeModelID,
            adapterID: capability.adapterID, artifactSHA256: capability.artifactSHA256,
            planSHA256: configuration.selectedPlanSHA256, prefillSchedule: configuration.selectedPrefillSchedule.rawValue,
            stages: partition.stages.map { stage in
                .init(rank: stage.rank, peerID: configuration.peers[stage.rank].id, local: stage.rank == configuration.localRank,
                    sourceLayerStart: stage.sourceLayerStart, sourceLayerEnd: stage.sourceLayerEnd)
            },
            maximumLifetimeSeconds: capability.maxLifetimeSeconds, maximumRequests: capability.maxRequests,
            maximumPromptTokens: capability.profile.maximumPromptTokens,
            maximumOutputTokens: capability.profile.maximumOutputTokens)
    }
}

/// The saved setup as this Mac holds it.
public struct ClusterConsoleSavedSetup: Encodable, Sendable, Equatable {
    public enum State: String, Encodable, Sendable { case notConfigured, loaded, unreadable }
    public let state: State
    /// Why a saved setup could not be read; nil otherwise.
    public let error: String?
    /// SHA-256 of the saved canonical configuration: the setup's identity.
    public let configurationSHA256: String?
    public let pairing: ClusterConsolePairing?
    public let model: ClusterConsoleSavedModel?
    public let installed: ClusterConsoleInstalled?

    static let notConfigured = ClusterConsoleSavedSetup(state: .notConfigured, error: nil, configurationSHA256: nil,
        pairing: nil, model: nil, installed: nil)

    /// Reads the referenced setup with the store's own strict reader, then
    /// looks at what it names on this Mac. Nothing is written. `deadline` is a
    /// `DispatchTime` uptime in nanoseconds for the installed-file checks.
    static func read(reference: ClusterConfigurationReference?, paths: ClusterUserPaths, deadline: UInt64) -> ClusterConsoleSavedSetup {
        guard let reference else { return .notConfigured }
        do {
            let saved = try ClusterConfigurationStore(paths: paths).load(reference: reference)
            return .init(state: .loaded, error: nil, configurationSHA256: reference.sha256,
                pairing: .init(configuration: saved.configuration),
                model: try .init(configuration: saved.configuration, capability: saved.capability),
                installed: .inspect(saved: saved, paths: paths, deadline: deadline))
        } catch {
            return .init(state: .unreadable, error: ClusterConsoleText.bounded(error), configurationSHA256: reference.sha256,
                pairing: nil, model: nil, installed: nil)
        }
    }
}
