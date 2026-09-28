import DarkbloomClusterProtocol
@_spi(ProtectedExperiment) import DarkbloomClusterRuntime
@_spi(Benchmark) import DarkbloomClusterRuntime
import Foundation

/// Exactly one native executor uses this wrapper; cancel is the facade's
/// explicitly thread-safe operation. No model or tensor crosses the pipe.
final class NativeWorkerRuntime: WorkerRuntime, @unchecked Sendable {
    private let owner: QwenResidentRuntime
    private let evidence: ResidentEvidenceSink?
    private var active: (id: UUID, deadline: UInt64)?
    init(_ configuration: QwenResidentLoadConfiguration, bootstrap: WorkerBootstrapConfiguration? = nil,
         protection: WorkerProtectedConfiguration? = nil, evidenceDirectory: String? = nil) throws {
        if let evidenceDirectory {
            guard protection != nil else { throw WorkerFailure.invalid("Numerical export requires protected execution") }
            evidence = try ResidentEvidenceSink(path: evidenceDirectory)
        } else { evidence = nil }
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
    var readiness: ClusterWorkerReady? {
        if evidence != nil { return try? owner.recordingReadiness(prefillPolicy: .serial) }
        return owner.readiness
    }
    func reserve(_ id: UUID, _ value: ClusterWorkerReservation) throws -> Int {
        guard active == nil else { throw WorkerFailure.invalid("Native request already active") }
        let bytes: Int
        if evidence != nil { bytes = try owner.reserveRecording(requestID: id, request: value, prefillPolicy: .serial) }
        else { bytes = try owner.reserve(requestID: id, request: value) }
        active = (id, value.deadlineUptimeNanoseconds)
        return bytes
    }
    func start(_ id: UUID, token: (Int, Int, Int) throws -> Bool) throws -> ClusterWorkerFinishReason {
        guard let active, active.id == id else { throw WorkerFailure.invalid("Native start lacks its exact reservation") }
        let result: QwenResidentGenerationCompletion
        if let evidence {
            result = try owner.startRecording(requestID: id, onCommittedToken: token) { bytes, liveCheck in
                try evidence.publish(bytes, requestID: id, deadline: active.deadline, resourceCheck: liveCheck)
            }
        } else { result = try owner.start(requestID: id, onCommittedToken: token) }
        guard result.requestID == id, result.bothRequestStatesRetired else { throw WorkerFailure.invalid("Native generation did not retire both request states") }
        self.active = nil
        return result.finishReason
    }
    func cancel(_ id: UUID) { owner.cancel(requestID: id) }
    func shutdown() throws { try owner.shutdown(); active = nil }
}
