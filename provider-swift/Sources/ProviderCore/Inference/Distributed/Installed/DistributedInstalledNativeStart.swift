import CryptoKit
import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity

/// The committed native start of each rank under the combined owner profile
/// (S07), derived from the installed setup. Both Macs derive the same common
/// part from their own saved setup and pinned capability (everything except
/// the epoch is a fact both setups pin), so an owner admits a start exactly
/// when its common part is the one it derives itself for that epoch. The
/// leader mints the per-rank owner incarnation, lease and launch.
///
/// The record limits bound an encrypted data plane that is not built yet
/// (S16): the key the prelude confirms is held by each worker, never used.
enum DistributedInstalledNativeStart {
    static let maximumRecordPlaintextBytes = 1 << 20

    static func common(plan: DistributedInstalledPlan, epoch: UUID) throws -> ClusterNativeAuthorizationCommon {
        let configuration = plan.configuration, capability = plan.capability
        func digest(_ fields: [String]) -> Data {
            Data(SHA256.hash(data: Data(fields.joined(separator: "\u{1F}").utf8)))
        }
        func bytes(_ hex: String) throws -> Data {
            guard hex.utf8.count == 64 else { throw ClusterConfigurationError.invalid("Native start digest differs") }
            var result = Data(capacity: 32), index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                guard let value = UInt8(hex[index..<next], radix: 16) else { throw ClusterConfigurationError.invalid("Native start digest differs") }
                result.append(value); index = next
            }
            return result
        }
        let peers = configuration.peers.flatMap { [$0.id, String($0.rank), $0.runtimeBinarySHA256, $0.jacclDevice] }
        let profile = capability.profile
        let limits = try ClusterRecordLimits(maximumPlaintextBytes: maximumRecordPlaintextBytes)
        return try .init(epoch: epoch, membershipGeneration: 1, nativePolicyGeneration: 1,
            membershipTranscriptSHA256: digest(["darkbloom/installed-membership/v1", configuration.clusterID,
                configuration.selectedPlanSHA256, configuration.selectedPrefillSchedule.rawValue,
                configuration.selectedGenerationMode.rawValue] + peers),
            approvedNativeBindingSHA256: digest(["darkbloom/installed-native-binding/v1", capability.runtimeBinarySHA256,
                capability.adapterID, String(capability.adapterVersion)]),
            planSHA256: try bytes(plan.partition.planSHA256), artifactSHA256: try bytes(capability.artifactSHA256),
            nativeRuntimeSHA256: try bytes(capability.runtimeBinarySHA256),
            capabilitySHA256: try bytes(configuration.capabilitySHA256),
            resourcePolicySHA256: digest(["darkbloom/installed-resource-policy/v1", capability.arithmeticPolicyID,
                capability.arithmeticPolicySHA256, capability.stateSemantics, capability.schedulingPolicy]),
            profileSHA256: digest(["darkbloom/installed-profile/v1", profile.id, String(profile.vocabularySize),
                String(profile.maximumPromptTokens), String(profile.maximumOutputTokens), String(profile.maximumChunkTokens),
                String(profile.maximumContextTokens), capability.profileFingerprint]),
            schedule: configuration.selectedPrefillSchedule == .serial ? .serial : .oneChunkLookahead,
            maximumTransportFrameBytes: maximumRecordPlaintextBytes + 40, limits: limits)
    }

    /// Fresh starts for one session: one common, a new owner incarnation,
    /// lease and launch per rank.
    static func starts(plan: DistributedInstalledPlan, epoch: UUID) throws -> [ClusterNativeAuthorizationStart] {
        let common = try common(plan: plan, epoch: epoch)
        return try (0...1).map { try .init(common: common, rank: $0, ownerIncarnation: UUID(), leaseID: UUID(), launchID: UUID()) }
    }

    /// The owner's admission of a start: its own rank, and the common part this
    /// Mac derives for that start's epoch.
    static func authorizer(plan: DistributedInstalledPlan) -> @Sendable (ClusterNativeAuthorizationStart) throws -> Void {
        { start in
            guard start.rank == plan.configuration.localRank,
                  try common(plan: plan, epoch: start.common.epoch).canonicalBytes == start.common.canonicalBytes else {
                throw ClusterConfigurationError.invalid("The committed native start differs from this Mac's installed setup")
            }
        }
    }
}
