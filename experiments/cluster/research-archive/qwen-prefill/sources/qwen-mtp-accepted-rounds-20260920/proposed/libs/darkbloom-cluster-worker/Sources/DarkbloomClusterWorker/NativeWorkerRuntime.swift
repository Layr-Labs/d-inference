import DarkbloomClusterProtocol
@_spi(Benchmark) import DarkbloomClusterRuntime
import Foundation

/// Private paired correctness worker. Default installed capability is unchanged.
/// Both modes use this same worker/owner; there is no second request route.
final class NativeWorkerRuntime: WorkerRuntime, @unchecked Sendable {
    private enum Mode: String { case off, depth1 }
    private let owner: QwenResidentRuntime
    private let mode: Mode
    private let sink: ResidentEvidenceSink
    private var active: (id: UUID, deadline: UInt64)?
    private var used = false

    init(_ configuration: QwenResidentLoadConfiguration, bootstrap: WorkerBootstrapConfiguration? = nil) throws {
        guard let bootstrap,
              let raw = ProcessInfo.processInfo.environment["DARKBLOOM_PRIVATE_QWEN_MTP_MODE"],
              let mode = Mode(rawValue: raw),
              let path = ProcessInfo.processInfo.environment["DARKBLOOM_BENCHMARK_EVIDENCE_DIR"],
              configuration.identity.modelID == "registered_qwen35_9b", configuration.stageCut == 4,
              configuration.prefillSchedule == .serial, configuration.allocatorPolicy == .disableFreedBufferCache else {
            throw WorkerFailure.invalid("Private MTP correctness requires explicit off/depth1, registered9B cut4/serial/cache0 and owned bootstrap/evidence")
        }
        self.mode = mode; sink = try ResidentEvidenceSink(path: path)
        let attachment = try bootstrap.connect(epoch: configuration.identity.membershipEpoch, rank: configuration.rank)
        let native = QwenResidentBootstrap(connection: attachment)
        switch mode {
        case .off: owner = try .load(configuration, bootstrap: native)
        case .depth1: owner = try .loadForMTPAcceptedValidation(configuration, bootstrap: native)
        }
    }

    var readiness: ClusterWorkerReady? {
        guard !used else { return nil }
        switch mode {
        case .off: return try? owner.recordingReadiness()
        case .depth1: return owner.readiness
        }
    }

    func reserve(_ id: UUID, _ value: ClusterWorkerReservation) throws -> Int {
        guard !used, active == nil, (1...32).contains(value.promptTokenIDs.count),
              (1...16).contains(value.chunkSize), (2...8).contains(value.outputCount), value.stopTokenIDs.isEmpty else {
            throw WorkerFailure.invalid("MTP correctness request exceeds private short scope or repeats")
        }
        let bytes: Int
        switch mode {
        case .off: bytes = try owner.reserveRecording(requestID: id, request: value)
        case .depth1: bytes = try owner.reserveMTPAccepted(requestID: id, request: value)
        }
        active = (id, value.deadlineUptimeNanoseconds)
        return bytes
    }

    func start(_ id: UUID, token: (Int, Int, Int) throws -> Bool) throws -> ClusterWorkerFinishReason {
        guard let reservation = active, reservation.id == id, !used else {
            throw WorkerFailure.invalid("MTP correctness start has no retained request")
        }
        used = true
        let completion: QwenResidentGenerationCompletion, bytes: Data
        switch mode {
        case .off:
            let value = try owner.startRecording(requestID: id, onCommittedToken: token)
            completion = value.completion; bytes = value.encodedEvidence
        case .depth1:
            let value = try owner.startMTPAccepted(requestID: id, onCommittedToken: token)
            completion = value.completion; bytes = value.encodedEvidence
        }
        guard completion.requestID == id, completion.bothRequestStatesRetired else {
            throw WorkerFailure.invalid("MTP correctness return precedes matching bilateral retirement")
        }
        // The actual owner must retain/fence this worker until publication,
        // shutdown, normal child exit, diagnostic drain and lease ACK complete.
        try sink.publish(bytes, requestID: id, deadline: reservation.deadline)
        active = nil
        return completion.finishReason
    }
    func cancel(_ id: UUID) { owner.cancel(requestID: id) }
    func shutdown() throws { try owner.shutdown(); active = nil }
}
