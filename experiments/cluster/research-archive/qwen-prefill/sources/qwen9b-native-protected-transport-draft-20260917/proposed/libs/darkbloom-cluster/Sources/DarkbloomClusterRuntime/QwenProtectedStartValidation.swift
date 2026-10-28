import DarkbloomClusterBootstrap
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation

/// Pure local equality checks. They do not mint a prelude context, accept a
/// coordinator grant, verify an executable, or allocate any native storage.
enum QwenProtectedStartValidation {
    static func require(_ start: ClusterNativeAuthorizationStart, admission: QwenResidentAdmission,
                        bootstrapIdentity: ClusterBootstrapIdentity, bootstrapDeadline: UInt64) throws {
        let c = start.common, configuration = admission.configuration
        guard configuration.stageCut == QwenResidentProtectedExperiment.cut,
              configuration.allocatorPolicy == .disableFreedBufferCache,
              configuration.prefillSchedule == .serial,
              c.schedule == .serial, start.rank == configuration.rank,
              c.epoch == configuration.identity.membershipEpoch,
              bootstrapDeadline > 0, bootstrapDeadline <= configuration.deadlineUptimeNanoseconds,
              bootstrapIdentity.membershipEpoch == c.epoch, bootstrapIdentity.rank == start.rank,
              c.planSHA256 == (try collectiveRecordDigest(admission.plan.fingerprint)),
              c.artifactSHA256 == (try collectiveRecordDigest(admission.specification.artifactSHA256)),
              c.profileSHA256 == (try collectiveRecordDigest(admission.profile.fingerprint)),
              c.resourcePolicySHA256 == (try collectiveRecordDigest(sha256(QwenResidentProtectedExperiment.resourcePolicyBytes()))),
              c.maximumTransportFrameBytes == QwenResidentProtectedExperiment.maximumFrameBytes,
              c.limits.maximumPlaintextBytes == QwenResidentProtectedExperiment.maximumPlaintextBytes,
              c.limits.maximumRecordsPerDirection == QwenResidentProtectedExperiment.maximumRecords,
              c.limits.maximumCumulativePlaintextBytesPerDirection == QwenResidentProtectedExperiment.maximumCumulativeBytes,
              configuration.identity.peers.allSatisfy({
                  (try? collectiveRecordDigest($0.buildSHA256)) == c.nativeRuntimeSHA256
              }) else { throw ProbeError("Protected native start differs from admitted model, workload or resource policy") }
        let runtimeHash = c.nativeRuntimeSHA256.map { String(format: "%02x", $0) }.joined()
        let capability = try QwenResidentCapabilityMetadata.describe(configuration: admission.configBytes,
            manifest: admission.manifestBytes, runtimeBinarySHA256: runtimeHash)
        guard c.capabilitySHA256 == (try collectiveRecordDigest(sha256(ClusterRuntimeCapabilityCodec.encode(capability)))) else {
            throw ProbeError("Protected start capability differs from the actual registered constructor")
        }
    }
}
