import Foundation
@testable import MLXLMCommon

/// Direct backend state at the real prefill-completion callback, not consumer
/// delivery time, a lagging published gauge, or a whole-process memory peak.
struct ModelPrefixBenchmarkPrefillMemoryObservation: Codable, Sendable {
    let observationPoint: String
    let callbackCount: Int
    let requestID: UInt64
    let promptTokens: Int
    let restoredTokens: Int
    let backendBytesInUse: Int
    let backendBytesReserved: Int
    let backendBytesCapacity: Int
    let pagedGeneration: UUID?
    let pagedCommittedBytes: Int?
    let pagedLiveBytes: Int?
    let pagedReservedBytes: Int?

    init(requestID: CBv2RequestID, usage: CBv2Usage, engine: EngineV2) {
        let backend = engine.loopForTesting.backend
        let paged = (backend as? PagedKVBackend)?.pool.segmentStorageSnapshot
        observationPoint = "engine_queue_prefill_completion"
        callbackCount = 1
        self.requestID = requestID.raw
        promptTokens = usage.promptTokens
        restoredTokens = usage.prefixCachePrefillTokensSaved
        backendBytesInUse = backend.bytesInUse
        backendBytesReserved = backend.bytesReserved
        backendBytesCapacity = backend.bytesCapacity
        pagedGeneration = paged?.generation
        pagedCommittedBytes = paged?.committedBytes
        pagedLiveBytes = paged?.livePageBytes
        pagedReservedBytes = paged?.reservedPageBytes
    }
}

final class ModelPrefixBenchmarkPrefillMemoryCapture: @unchecked Sendable {
    enum Failure: Error { case missingOrRepeatedCallback }
    private let requestID: CBv2RequestID
    private let lock = NSLock()
    private var count = 0
    private var first: ModelPrefixBenchmarkPrefillMemoryObservation?

    init(requestID: CBv2RequestID) { self.requestID = requestID }

    /// Called only by CBv2Request.onPrefillCompleted, already on the engine queue.
    func record(usage: CBv2Usage, engine: EngineV2) {
        let observation = ModelPrefixBenchmarkPrefillMemoryObservation(
            requestID: requestID, usage: usage, engine: engine)
        lock.withLock {
            count += 1
            if first == nil { first = observation }
        }
    }

    func snapshot() throws -> ModelPrefixBenchmarkPrefillMemoryObservation {
        try lock.withLock {
            guard count == 1, let first else { throw Failure.missingOrRepeatedCallback }
            return first
        }
    }
}
