import DarkbloomClusterProtocol
@_spi(Benchmark) import DarkbloomClusterRuntime
import Foundation

/// Private phase-only validation worker, built separately from c35c and the
/// ordinary serving/timing worker. Uses the same admitted owner/core/sidecar IO.
final class NativeWorkerRuntime: WorkerRuntime, @unchecked Sendable {
    private let owner: QwenResidentRuntime
    private let sink: ResidentEvidenceSink
    private let prefillPolicy: QwenResidentPrefillPolicy
    private var active: (id: UUID, deadline: UInt64)?

    init(_ configuration: QwenResidentLoadConfiguration, bootstrap: WorkerBootstrapConfiguration? = nil) throws {
        guard configuration.stageCut == 16,
              configuration.identity.modelID == QwenResidentNativeValidationModel.qwen38TwentySevenB.runtimeModelID else {
            throw WorkerFailure.invalid("Phase worker requires registered 27B cut16/48")
        }
        let environment = ProcessInfo.processInfo.environment
        let selected = try BenchmarkPrefillPolicy.parse(environment[BenchmarkPrefillPolicy.environmentName])
        switch selected {
        case .serial: prefillPolicy = .serial
        case .oneChunkLookahead: prefillPolicy = .oneChunkLookahead
        }
        guard let bootstrap,
              let path = environment["DARKBLOOM_BENCHMARK_EVIDENCE_DIR"] else {
            throw WorkerFailure.invalid("Private benchmark requires owner bootstrap and an evidence directory")
        }
        sink = try ResidentEvidenceSink(path: path)
        let attachment = try bootstrap.connect(epoch: configuration.identity.membershipEpoch, rank: configuration.rank)
        owner = try .load(configuration, bootstrap: QwenResidentBootstrap(connection: attachment))
    }

    var readiness: ClusterWorkerReady? { try? owner.phaseObservationReadiness(prefillPolicy: prefillPolicy) }

    func reserve(_ id: UUID, _ value: ClusterWorkerReservation) throws -> Int {
        guard active == nil else { throw WorkerFailure.invalid("Benchmark request already active") }
        let bytes = try owner.reservePhaseObservation(requestID: id, request: value, prefillPolicy: prefillPolicy)
        active = (id, value.deadlineUptimeNanoseconds)
        return bytes
    }

    func start(_ id: UUID, token: (Int, Int, Int) throws -> Bool) throws -> ClusterWorkerFinishReason {
        guard let reservation = active, reservation.id == id else {
            throw WorkerFailure.invalid("Benchmark start has no matching reservation")
        }
        let result = try owner.startPhaseObservation(requestID: id, onCommittedToken: token) { bytes, liveCheck in
            // No output or borrowed check escapes this synchronous callback.
            // The owner restores capacity only after the sink and buffer retire.
            try sink.publish(bytes, requestID: id, deadline: reservation.deadline, resourceCheck: liveCheck)
        }
        guard result.requestID == id, result.bothRequestStatesRetired else {
            throw WorkerFailure.invalid("Phase generation returned without matching retirement")
        }
        active = nil
        return result.finishReason
    }

    func cancel(_ id: UUID) { owner.cancel(requestID: id) }
    func shutdown() throws { try owner.shutdown(); active = nil }
}
