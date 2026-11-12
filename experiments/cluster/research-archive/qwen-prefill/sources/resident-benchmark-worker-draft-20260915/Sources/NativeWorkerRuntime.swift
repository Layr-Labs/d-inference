import DarkbloomClusterProtocol
@_spi(Benchmark) import DarkbloomClusterRuntime
import Foundation

/// Private evidence-producing wrapper around the actual shared generation SPI.
/// The public serving worker retains its normal non-recording wrapper.
final class NativeWorkerRuntime: WorkerRuntime, @unchecked Sendable {
    private let owner: QwenResidentRuntime
    private let sink: ResidentEvidenceSink
    private var active: (id: UUID, deadline: UInt64)?

    init(_ configuration: QwenResidentLoadConfiguration, bootstrap: WorkerBootstrapConfiguration? = nil) throws {
        guard let bootstrap,
              let path = ProcessInfo.processInfo.environment["DARKBLOOM_BENCHMARK_EVIDENCE_DIR"] else {
            throw WorkerFailure.invalid("Private benchmark requires owner bootstrap and an evidence directory")
        }
        sink = try ResidentEvidenceSink(path: path)
        let attachment = try bootstrap.connect(epoch: configuration.identity.membershipEpoch, rank: configuration.rank)
        owner = try .load(configuration, bootstrap: QwenResidentBootstrap(connection: attachment))
    }

    var readiness: ClusterWorkerReady? { try? owner.recordingReadiness() }

    func reserve(_ id: UUID, _ value: ClusterWorkerReservation) throws -> Int {
        guard active == nil else { throw WorkerFailure.invalid("Benchmark request already active") }
        let bytes = try owner.reserveRecording(requestID: id, request: value)
        active = (id, value.deadlineUptimeNanoseconds)
        return bytes
    }

    func start(_ id: UUID, token: (Int, Int, Int) throws -> Bool) throws -> ClusterWorkerFinishReason {
        guard let reservation = active, reservation.id == id else {
            throw WorkerFailure.invalid("Benchmark start has no matching reservation")
        }
        let result = try owner.startRecording(requestID: id, onCommittedToken: token)
        guard result.completion.requestID == id, result.completion.bothRequestStatesRetired else {
            throw WorkerFailure.invalid("Benchmark generation returned without matching retirement")
        }
        // Coordinator cannot emit finished/retired until this returns. A write
        // failure makes this worker fail; no successful sidecar is fabricated.
        try sink.publish(result.encodedEvidence, requestID: id, deadline: reservation.deadline)
        active = nil
        return result.completion.finishReason
    }

    func cancel(_ id: UUID) { owner.cancel(requestID: id) }
    func shutdown() throws { try owner.shutdown(); active = nil }
}
