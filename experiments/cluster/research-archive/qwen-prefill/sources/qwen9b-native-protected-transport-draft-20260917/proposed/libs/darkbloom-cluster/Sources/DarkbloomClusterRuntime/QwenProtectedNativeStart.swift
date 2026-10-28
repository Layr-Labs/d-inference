import DarkbloomClusterBootstrap
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation

/// Immutable public start + actual PID-bound socket. Public fields alone cannot
/// construct the opaque A context or traffic keys. The shared resident loader
/// owns the process lease before calling establish, and remains the state owner.
struct QwenProtectedNativeStart {
    let connection: ClusterBootstrapConnection
    let start: ClusterNativeAuthorizationStart

    init(connection: ClusterBootstrapConnection, startBytes: Data, profile: String) throws {
        guard profile == QwenResidentProtectedExperiment.identifier,
              (1...4096).contains(startBytes.count) else { throw ProbeError("Unknown native protected experiment") }
        start = try .init(encoded: startBytes)
        guard start.canonicalBytes == startBytes,
              connection.identity.membershipEpoch == start.common.epoch,
              connection.identity.rank == start.rank else { throw ProbeError("Protected start differs from its native socket") }
        self.connection = connection
    }

    func require(_ admission: QwenResidentAdmission) throws {
        try QwenProtectedStartValidation.require(start, admission: admission,
            bootstrapIdentity: connection.identity, bootstrapDeadline: connection.deadlineUptimeNanoseconds)
    }

    func establish(_ admission: QwenResidentAdmission, recordBudget: QwenProtectedRecordBudget) throws -> CollectiveProtectionConfiguration {
        try require(admission)
        try QwenProtectedResources.requireLive()
        let context = try connection.beginNativeKeyPrelude(expecting: start.canonicalBytes)
        let authority = try ClusterNativeRecordAuthority(ownedPrelude: context)
        do {
            let receipt = try authority.establish()
            guard receipt.epoch == start.common.epoch, receipt.rank == start.rank else {
                throw ProbeError("Native key receipt differs from its admitted start")
            }
            let binding = try ClusterRecordBinding(epoch: receipt.epoch, planSHA256: start.common.planSHA256,
                membershipTranscriptSHA256: receipt.transcriptSHA256)
            return .init(authority: authority, binding: binding, limits: start.common.limits,
                maximumFrameBytes: start.common.maximumTransportFrameBytes, recordBudget: recordBudget)
        } catch { authority.invalidate(); throw error }
    }
}

extension QwenResidentRuntime {
    /// Private experiment SPI. The dedicated native child retains its existing
    /// hard process alarm, actual owner and canonical lease obligations.
    @_spi(ProtectedExperiment) public static func loadProtectedExperiment(
        _ configuration: QwenResidentLoadConfiguration, connection: ClusterBootstrapConnection,
        authorizationStart: Data, profile: String
    ) throws -> QwenResidentRuntime {
        do {
            let requested = try QwenProtectedNativeStart(connection: connection,
                startBytes: authorizationStart, profile: profile)
            return try loadNative(configuration, bootstrap: .init(connection: connection),
                protection: nil, nativeStart: requested)
        } catch { connection.cancel(); throw error }
    }
}
