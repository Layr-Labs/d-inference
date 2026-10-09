import DarkbloomClusterProtocol
@_spi(Benchmark) import DarkbloomClusterRuntime
import Foundation

/// The same resident owner driven through its recording entry, selected only by
/// `--evidence-directory`. After a request both ranks have retired, this rank's
/// evidence (selected tokens, state digests and, on rank 1, the final logits
/// row) is written to that directory before `finished` is published. A worker
/// started without the flag never constructs this type.
///
/// Both ranks of a pair must be started the same way. Timings taken from a
/// recording worker are not serving timings.
final class RecordingWorkerRuntime: WorkerRuntime, @unchecked Sendable {
    private let owner: QwenResidentRuntime
    private let sink: WorkerEvidenceSink
    private let policy: QwenResidentPrefillPolicy
    private var active: (id: UUID, deadline: UInt64)?

    init(_ configuration: QwenResidentLoadConfiguration, bootstrap: WorkerBootstrapConfiguration? = nil,
         evidenceDirectory: String) throws {
        guard bootstrap == nil else {
            throw WorkerFailure.invalid("The authenticated bootstrap attachment is not available in this build")
        }
        // Opened before any model work: an unusable directory fails the launch.
        sink = try WorkerEvidenceSink(path: evidenceDirectory)
        switch configuration.prefillSchedule {
        case .serial: policy = .serial
        case .oneChunkLookahead: policy = .oneChunkLookahead
        }
        owner = try .load(configuration)
    }

    /// The recording ceiling: the serving allowance plus the capture terms.
    var readiness: ClusterWorkerReady? { try? owner.recordingReadiness(prefillPolicy: policy) }

    func reserve(_ id: UUID, _ value: ClusterWorkerReservation) throws -> Int {
        guard active == nil else { throw WorkerFailure.invalid("Recording request already active") }
        let bytes = try owner.reserveRecording(requestID: id, request: value, prefillPolicy: policy)
        active = (id, value.deadlineUptimeNanoseconds)
        return bytes
    }

    func start(_ id: UUID, token: (Int, Int, Int) throws -> Bool) throws -> ClusterWorkerFinishReason {
        guard let reservation = active, reservation.id == id else {
            throw WorkerFailure.invalid("Recording start has no matching reservation")
        }
        let result = try owner.startRecording(requestID: id, onCommittedToken: token)
        guard result.completion.requestID == id, result.completion.bothRequestStatesRetired else {
            throw WorkerFailure.invalid("Recording generation returned without matching retirement")
        }
        // The coordinator cannot publish finished/retired until this returns. A
        // write failure fails the worker; no successful sidecar is fabricated.
        try sink.publish(result.encodedEvidence, requestID: id, deadline: reservation.deadline)
        active = nil
        return result.completion.finishReason
    }

    func cancel(_ id: UUID) { owner.cancel(requestID: id) }
    func shutdown() throws { try owner.shutdown(); active = nil }
}
