import DarkbloomClusterProtocol
@_spi(ProtectedExperiment) import DarkbloomClusterRuntime
import Foundation

/// Exactly one native executor uses this wrapper; cancel is the facade's
/// explicitly thread-safe operation. No model or tensor crosses the pipe.
final class NativeWorkerRuntime: WorkerRuntime, @unchecked Sendable {
    private let owner: QwenResidentRuntime
    init(_ configuration: QwenResidentLoadConfiguration, bootstrap: WorkerBootstrapConfiguration? = nil,
         protection: WorkerProtectedConfiguration? = nil) throws {
        if let protection {
            guard let bootstrap else { throw WorkerFailure.invalid("Protected native bootstrap is required") }
            let attachment = try bootstrap.connect(epoch: configuration.identity.membershipEpoch,
                rank: configuration.rank, mode: .nativeKeyPreludeV1)
            owner = try .loadProtectedExperiment(configuration, connection: attachment,
                authorizationStart: protection.start, profile: protection.profile)
        } else {
            let attachment = try bootstrap?.connect(epoch: configuration.identity.membershipEpoch, rank: configuration.rank)
            owner = try .load(configuration, bootstrap: attachment.map { QwenResidentBootstrap(connection: $0) })
        }
    }
    var readiness: ClusterWorkerReady? { owner.readiness }
    func reserve(_ id: UUID, _ value: ClusterWorkerReservation) throws -> Int {
        try owner.reserve(requestID: id, request: value)
    }
    func start(_ id: UUID, token: (Int, Int, Int) throws -> Bool) throws -> ClusterWorkerFinishReason {
        let result = try owner.start(requestID: id, onCommittedToken: token)
        guard result.bothRequestStatesRetired else { throw WorkerFailure.invalid("Native generation did not retire both request states") }
        return result.finishReason
    }
    func cancel(_ id: UUID) { owner.cancel(requestID: id) }
    func shutdown() throws { try owner.shutdown() }
}
