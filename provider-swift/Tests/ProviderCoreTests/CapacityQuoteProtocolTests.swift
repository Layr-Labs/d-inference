// Wire symmetry for the routing-v2 capacity protocol: capacity_probe
// (decode), capacity_quote (encode), the heartbeat capacity payload's
// capacity_seq, and the enriched inference_error fields. Key casing and
// optional-field omission are pinned byte-for-byte against
// coordinator/protocol/capacity.go — the Go side has the mirror tests.

import Foundation
import Testing
@testable import ProviderCore

private enum QuoteTestFailure: Error {
    case unexpectedMessage
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func slot(
    model: String = "org/model-a",
    state: String = "running",
    numRunning: UInt32 = 1
) -> BackendSlotCapacity {
    BackendSlotCapacity(
        model: model,
        state: state,
        numRunning: numRunning,
        numWaiting: 0,
        activeTokens: 100,
        maxTokensPotential: 8192,
        maxConcurrency: 4,
        observedDecodeTps: 40,
        observedPrefillTps: 900,
        activeTokenBudgetUsed: 1000,
        activeTokenBudgetMax: 9192,
        queuedTokenBudget: 0)
}

private func capacity(seq: UInt64) -> BackendCapacity {
    BackendCapacity(
        slots: [slot()],
        gpuMemoryActiveGb: 1,
        gpuMemoryPeakGb: 2,
        gpuMemoryCacheGb: 0.5,
        totalMemoryGb: 64,
        freeForLoadGb: 30,
        capacitySeq: seq)
}

// MARK: - capacity_seq on the heartbeat capacity payload

@Test func heartbeatCapacitySeqRidesBackendCapacityAndOmitsZero() throws {
    let stamped = ProviderMessage.heartbeat(ProviderMessage.Heartbeat(
        status: .serving,
        stats: ProviderStats(),
        systemMetrics: SystemMetrics(memoryPressure: 0, cpuUsage: 0, thermalState: .nominal),
        backendCapacity: capacity(seq: 42)))
    let stampedObj = try object(try ProviderProtocolCodec.encodeProviderMessage(stamped))
    let backend = try #require(stampedObj["backend_capacity"] as? [String: Any])
    #expect(backend["capacity_seq"] as? UInt64 == 42)
    // Seq lives on the capacity payload, never at heartbeat top level.
    #expect(stampedObj["capacity_seq"] == nil)

    // Unstamped (0) keeps the legacy wire shape byte-identical.
    let legacy = ProviderMessage.heartbeat(ProviderMessage.Heartbeat(
        status: .serving,
        stats: ProviderStats(),
        systemMetrics: SystemMetrics(memoryPressure: 0, cpuUsage: 0, thermalState: .nominal),
        backendCapacity: capacity(seq: 0)))
    let legacyObj = try object(try ProviderProtocolCodec.encodeProviderMessage(legacy))
    let legacyBackend = try #require(legacyObj["backend_capacity"] as? [String: Any])
    #expect(legacyBackend.keys.contains("capacity_seq") == false)

    // Legacy payloads without the key decode as 0; stamped ones round-trip.
    guard case .heartbeat(let decoded) = try ProviderProtocolCodec.decodeProviderMessage(
        from: try ProviderProtocolCodec.encodeProviderMessage(stamped))
    else { throw QuoteTestFailure.unexpectedMessage }
    #expect(decoded.backendCapacity?.capacitySeq == 42)
    guard case .heartbeat(let decodedLegacy) = try ProviderProtocolCodec.decodeProviderMessage(
        from: try ProviderProtocolCodec.encodeProviderMessage(legacy))
    else { throw QuoteTestFailure.unexpectedMessage }
    #expect(decodedLegacy.backendCapacity?.capacitySeq == 0)
}

// MARK: - capacity_probe (coordinator → provider, decode)

@Test func capacityProbeDecodesGoWireFormWithExactKeys() throws {
    let goWire = #"""
    {"type":"capacity_probe","quote_id":"q-7f3a","model":"org/model-a",
     "prompt_tokens_bucket":1536,"max_output_tokens":2048,
     "requires_vision":true,"vision_image_count":3,
     "deadline_remaining_ms":8400}
    """#
    guard case .capacityProbe(let probe) =
        try ProviderProtocolCodec.decodeCoordinatorMessage(from: goWire)
    else { throw QuoteTestFailure.unexpectedMessage }
    #expect(probe.quoteId == "q-7f3a")
    #expect(probe.model == "org/model-a")
    #expect(probe.promptTokensBucket == 1536)
    #expect(probe.maxOutputTokens == 2048)
    #expect(probe.requiresVision)
    #expect(probe.visionImageCount == 3)
    #expect(probe.deadlineRemainingMs == 8400)

    // Go `omitempty` vision fields absent → defaults, and re-encoding a
    // text probe never resurrects them.
    let textWire = #"{"type":"capacity_probe","quote_id":"q1","model":"m","prompt_tokens_bucket":512,"max_output_tokens":128,"deadline_remaining_ms":9000}"#
    guard case .capacityProbe(let textProbe) =
        try ProviderProtocolCodec.decodeCoordinatorMessage(from: textWire)
    else { throw QuoteTestFailure.unexpectedMessage }
    #expect(textProbe.requiresVision == false)
    #expect(textProbe.visionImageCount == 0)
    let reencoded = try object(
        try ProviderProtocolCodec.encodeCoordinatorMessage(.capacityProbe(textProbe)))
    #expect(reencoded["type"] as? String == "capacity_probe")
    #expect(reencoded.keys.contains("requires_vision") == false)
    #expect(reencoded.keys.contains("vision_image_count") == false)
    #expect(reencoded["prompt_tokens_bucket"] as? Int == 512)
    #expect(reencoded["deadline_remaining_ms"] as? Int64 == 9000)

    // The bucket granularity is part of the shared contract.
    #expect(CoordinatorMessage.CapacityProbe.promptBucketTokens == 512)
}

// MARK: - capacity_quote (provider → coordinator, encode)

@Test func capacityQuoteEncodesExactKeysAndOmitsReasonWhenAdmissible() throws {
    let admissible = ProviderMessage.capacityQuote(ProviderMessage.CapacityQuote(
        quoteId: "q-1",
        capacitySeq: 9,
        admissibleNow: true,
        ttftP50Ms: 850.5,
        ttftP90Ms: 1900.25,
        queueEstMs: 0,
        availableTokenBudget: 8192,
        confidence: .high))
    let obj = try object(try ProviderProtocolCodec.encodeProviderMessage(admissible))
    #expect(obj["type"] as? String == "capacity_quote")
    #expect(obj["quote_id"] as? String == "q-1")
    #expect(obj["capacity_seq"] as? UInt64 == 9)
    #expect(obj["admissible_now"] as? Bool == true)
    #expect(obj.keys.contains("rejection_reason") == false)
    #expect(obj["ttft_p50_ms"] as? Double == 850.5)
    #expect(obj["ttft_p90_ms"] as? Double == 1900.25)
    #expect(obj["queue_est_ms"] as? Double == 0)
    #expect(obj["available_token_budget"] as? Int64 == 8192)
    #expect(obj["confidence"] as? String == "high")

    let rejected = ProviderMessage.capacityQuote(ProviderMessage.CapacityQuote(
        quoteId: "q-2",
        capacitySeq: 10,
        admissibleNow: false,
        rejectionReason: .tokenBudget,
        ttftP50Ms: 1000,
        ttftP90Ms: 2000,
        queueEstMs: 350,
        availableTokenBudget: 12,
        confidence: .low))
    let rejectedObj = try object(try ProviderProtocolCodec.encodeProviderMessage(rejected))
    #expect(rejectedObj["admissible_now"] as? Bool == false)
    #expect(rejectedObj["rejection_reason"] as? String == "token_budget")
    #expect(rejectedObj["confidence"] as? String == "low")

    // Round trip.
    let decoded = try ProviderProtocolCodec.decodeProviderMessage(
        from: try ProviderProtocolCodec.encodeProviderMessage(rejected))
    #expect(decoded == rejected)

    // The type boundary pins the contract: a reason handed to an admissible
    // quote is dropped, never encoded.
    let contradictory = ProviderMessage.CapacityQuote(
        quoteId: "q-3", capacitySeq: 1, admissibleNow: true,
        rejectionReason: .deadline,
        ttftP50Ms: 1, ttftP90Ms: 2, queueEstMs: 0,
        availableTokenBudget: 0, confidence: .low)
    #expect(contradictory.rejectionReason == nil)
}

@Test func capacityRejectionReasonEnumMatchesGoConstants() {
    #expect(CapacityRejectionReason.allCases.map(\.rawValue) == [
        "token_budget", "kv_headroom", "memory_cap", "slot_state",
        "template", "capability", "deadline",
    ])
    #expect(CapacityQuoteConfidence.allCases.map(\.rawValue) == ["high", "low"])
}

// MARK: - enriched inference_error fields

@Test func inferenceErrorEnrichedFieldsEncodePresenceAndOmitempty() throws {
    let enriched = ProviderMessage.inferenceError(ProviderMessage.InferenceError(
        requestId: "req-1",
        failure: InferenceFailure(
            code: .capacity,
            statusCode: 503,
            errorReason: .tokenBudgetExhausted,
            rejectionReason: .tokenBudget,
            availableTokenBudget: 137,
            feasibleAfterMs: 450,
            capacitySeq: 21)))
    let obj = try object(try ProviderProtocolCodec.encodeProviderMessage(enriched))
    #expect(obj["rejection_reason"] as? String == "token_budget")
    #expect(obj["available_token_budget"] as? Int64 == 137)
    #expect(obj["feasible_after_ms"] as? Int64 == 450)
    #expect(obj["capacity_seq"] as? UInt64 == 21)

    // Bare legacy failure: none of the four keys appear.
    let bare = ProviderMessage.inferenceError(ProviderMessage.InferenceError(
        requestId: "req-2",
        failure: InferenceFailure(code: .capacity, statusCode: 503)))
    let bareObj = try object(try ProviderProtocolCodec.encodeProviderMessage(bare))
    for key in ["rejection_reason", "available_token_budget", "feasible_after_ms", "capacity_seq"] {
        #expect(bareObj.keys.contains(key) == false, "unexpected \(key)")
    }

    // feasible_after_ms / capacity_seq mirror Go omitempty (zero ≡ "no
    // estimate" / "unstamped": absent, so absent-decodes-as-zero agrees on
    // both sides). available_token_budget does NOT: presence semantics — an
    // explicit zero is real state ("busy slot, zero free tokens") and must
    // be encoded, or the coordinator falls back to its stale heartbeat
    // budget and can misclassify a transient reject as deterministic. The
    // Go mirror is `*int64`.
    let zeros = ProviderMessage.inferenceError(ProviderMessage.InferenceError(
        requestId: "req-3",
        failure: InferenceFailure(
            code: .capacity,
            statusCode: 503,
            availableTokenBudget: 0,
            feasibleAfterMs: 0,
            capacitySeq: 0)))
    let zerosObj = try object(try ProviderProtocolCodec.encodeProviderMessage(zeros))
    #expect(zerosObj["available_token_budget"] as? Int64 == 0)
    for key in ["feasible_after_ms", "capacity_seq"] {
        #expect(zerosObj.keys.contains(key) == false, "unexpected \(key)")
    }

    // The explicit zero survives a full round trip as a PRESENT zero, and
    // stays distinguishable from the omitted/nil legacy shape.
    let zeroRoundTrip = try ProviderProtocolCodec.decodeProviderMessage(
        from: try ProviderProtocolCodec.encodeProviderMessage(zeros))
    guard case .inferenceError(let zrt) = zeroRoundTrip else {
        throw QuoteTestFailure.unexpectedMessage
    }
    #expect(zrt.availableTokenBudget == 0)
    #expect(zrt.feasibleAfterMs == nil)
    #expect(zrt.capacitySeq == nil)
}

@Test func inferenceErrorLegacyFramesDecodeUnchangedAndUnknownReasonIsTolerated() throws {
    // A legacy frame without the additive fields decodes with nils.
    let legacy = #"{"type":"inference_error","request_id":"r","error":"capacity","status_code":503,"failure_code":"capacity"}"#
    guard case .inferenceError(let decoded) =
        try ProviderProtocolCodec.decodeProviderMessage(from: legacy)
    else { throw QuoteTestFailure.unexpectedMessage }
    #expect(decoded.rejectionReason == nil)
    #expect(decoded.availableTokenBudget == nil)
    #expect(decoded.feasibleAfterMs == nil)
    #expect(decoded.capacitySeq == nil)

    // A future rejection_reason value never crashes an older decoder.
    let future = #"{"type":"inference_error","request_id":"r","error":"capacity","status_code":503,"rejection_reason":"reason_from_the_future","available_token_budget":5,"capacity_seq":3}"#
    guard case .inferenceError(let tolerant) =
        try ProviderProtocolCodec.decodeProviderMessage(from: future)
    else { throw QuoteTestFailure.unexpectedMessage }
    #expect(tolerant.rejectionReason == nil)
    #expect(tolerant.availableTokenBudget == 5)
    #expect(tolerant.capacitySeq == 3)

    // Full round trip of an enriched frame.
    let message = ProviderMessage.inferenceError(ProviderMessage.InferenceError(
        requestId: "req-4",
        failure: InferenceFailure(
            code: .capacity,
            statusCode: 503,
            errorReason: .queueFull,
            rejectionReason: .kvHeadroom,
            availableTokenBudget: 99,
            feasibleAfterMs: 1200,
            capacitySeq: 8)))
    let roundTripped = try ProviderProtocolCodec.decodeProviderMessage(
        from: try ProviderProtocolCodec.encodeProviderMessage(message))
    guard case .inferenceError(let rt) = roundTripped else {
        throw QuoteTestFailure.unexpectedMessage
    }
    #expect(rt.rejectionReason == .kvHeadroom)
    #expect(rt.availableTokenBudget == 99)
    #expect(rt.feasibleAfterMs == 1200)
    #expect(rt.capacitySeq == 8)
}
