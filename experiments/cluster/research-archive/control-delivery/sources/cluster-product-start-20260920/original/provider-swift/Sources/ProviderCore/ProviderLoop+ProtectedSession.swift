import Foundation
import DarkbloomClusterProtocol

extension ProviderLoop {
    /// Internal attachment only. The existing signed coordinator transaction must
    /// already own the session. This does not create a replacement or enable an
    /// HTTP route whose token/stop contract exceeds the closed native workload.
    func protectedMemberSession(reference: ClusterConfigurationReference, providerConfiguration: URL,
                                deadlineUptimeNanoseconds: UInt64) async throws -> DistributedProtectedMemberSession {
        guard isClusterMember, let control = nativePairMemberControl else { throw NativePairMemberError.unconfigured }
        let claim = try control.retainedSessionClaim()
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let session = try await Task.detached(priority: .userInitiated) {
                    let prepared = try DistributedProtectedMemberPreparation.prepare(reference: reference,
                        providerConfiguration: providerConfiguration, installation: control.installation,
                        deadline: deadlineUptimeNanoseconds)
                    let plan = prepared.validation.plan, p = plan.capability.profile
                    let profile = try DistributedResidentExecutionProfile(id: p.id, vocabularySize: p.vocabularySize,
                        maxPromptTokens: p.maximumPromptTokens, maxOutputTokens: p.maximumOutputTokens,
                        maxContextTokens: p.maximumContextTokens,
                        requestTimeout: .seconds(plan.configuration.requestTimeoutSeconds))
                    let retained = try claim.claim(profile: profile, until: deadlineUptimeNanoseconds)
                    let identity = plan.identity(epoch: retained.epoch)
                    return try DistributedProtectedMemberSession(model: prepared.validation.model,
                        identity: .init(membershipEpoch: identity.membershipEpoch, modelID: identity.modelID,
                            artifactSHA256: identity.artifactSHA256, configurationSHA256: identity.configurationSHA256,
                            peers: identity.peers.map { .init(id: $0.id, buildSHA256: $0.buildSHA256) }),
                        profile: profile, backend: retained, retainMemberLoop: self,
                        installedBinding: try ClusterStatusBinding(configuration: plan.configuration, capability: plan.capability),
                        validateInputs: { try prepared.requireUnchanged() })
                }.value
                try Task.checkCancellation()
                return session
            } catch { claim.cancel(); throw error }
        } onCancel: { claim.cancel() }
    }
}
