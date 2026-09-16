import MLXLMCommon

extension EngineV2Bridge {
    func emitPrefixCacheColdFallback(
        requestId: String, reason: String, capacityRefusal: Bool
    ) {
        guard Self.shouldSamplePrefixTelemetry(&prefixCacheFallbackTelemetrySeen) else { return }
        emitPrefixCacheTelemetry(
            requestId: requestId, reason: reason, capacityRefusal: capacityRefusal,
            coldFallback: true, message: "engine_v2: prefix reuse fell back cold")
    }

    /// Content-free outcomes: only bounded enums, booleans, and aggregate
    /// counts enter telemetry, never token IDs or prompt/cache identities.
    func emitPrefixReuseTelemetry(requestId: String, usage: CBv2Usage) {
        let reason: String
        let coldFallback: Bool
        switch usage.prefixCacheOutcome {
        case .hit:
            guard Self.shouldSamplePrefixTelemetry(&prefixCacheHitTelemetrySeen) else { return }
            reason = "hit"
            coldFallback = false
        case .skippedCapacity, .adoptionFailed:
            guard Self.shouldSamplePrefixTelemetry(&prefixCacheFallbackTelemetrySeen) else { return }
            reason = usage.prefixCacheOutcome == .skippedCapacity ? "skipped_capacity" : "adoption_failed"
            coldFallback = true
        case .disabled, .skippedPolicy, .miss:
            return
        }
        emitPrefixCacheTelemetry(
            requestId: requestId, reason: reason,
            capacityRefusal: usage.prefixCacheOutcome == .skippedCapacity,
            coldFallback: coldFallback, message: "engine_v2: exact prefix reuse resolved",
            usage: usage)
    }

    /// Hit and fallback samples have separate counters. Pre-submit and native
    /// fallback events share a counter so the aggregate rate stays bounded.
    private static func shouldSamplePrefixTelemetry(_ counter: inout UInt64) -> Bool {
        counter &+= 1
        return counter == 1 || counter.isMultiple(of: 64)
    }

    private func emitPrefixCacheTelemetry(
        requestId: String, reason: String, capacityRefusal: Bool,
        coldFallback: Bool, message: String, usage: CBv2Usage? = nil
    ) {
        var event = EngineHealthEvent.make(
            severity: coldFallback ? .warn : .info,
            message: message, operation: "prefix_cache_replay",
            model: modelId, kvBackend: kvBackendKind.rawValue,
            extra: [
                "reason": .string(reason),
                "prefix_reuse_strategy": .string(usage?.prefixCacheStrategy?.rawValue ?? "none"),
                "prefix_matched_tokens": .int(max(0, usage?.prefixCacheMatchedTokens ?? 0)),
                "prefix_replay_tokens": .int(max(0, usage?.prefixCacheReplayTokens ?? 0)),
                "prefix_saved_tokens": .int(max(0, usage?.prefixCachePrefillTokensSaved ?? 0)),
                "prefix_boundary_splits": .int(max(0, usage?.prefixCacheBoundarySplits ?? 0)),
                "prefix_capacity_refusal": .bool(capacityRefusal),
                "prefix_cold_fallback": .bool(coldFallback),
            ])
        event.requestId = requestId
        emit(event)
    }
}
