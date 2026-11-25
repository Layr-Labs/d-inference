import Logging
import MLXLMCommon

extension EngineV2Bridge {
    private static let earlyTerminalLogger = Logger(label: "darkbloom.EarlyTerminal")

    /// A retirement this close to the terminal came with it: the request had
    /// nothing left to publish, so it is not marked.
    static let retirementAfterTerminalMarkFloor: Duration = .milliseconds(1)

    /// Per-request evidence for `DARKBLOOM_PREFIX_CACHE_SSD_TERMINAL_BEFORE_PUBLICATION`:
    /// a request that asked to be answered before its complete-checkpoint
    /// publication, and whose retirement (that publication, then the rows'
    /// release) came after its terminal, is marked once it retires, with how
    /// long it held its capacity after the answer: one provider-log line and
    /// one `engine_health` event (`ssd_terminal_before_publication`).
    func noteRetirementAfterTerminal(requestId: String, held: Duration) {
        guard held >= Self.retirementAfterTerminalMarkFloor else { return }
        let heldMs = Int(held / .milliseconds(1))
        Self.earlyTerminalLogger.info(
            "Early terminal: request \(requestId) (\(modelId)) retired \(heldMs) ms after its answer, when its checkpoint publication settled")
        var event = EngineHealthEvent.make(
            severity: .info, message: "engine_v2: answered before its checkpoint publication",
            operation: "ssd_terminal_before_publication",
            model: modelId, kvBackend: kvBackendKind.rawValue,
            extra: ["retired_after_terminal_ms": .int(heldMs)])
        event.requestId = requestId
        emit(event)
    }

    /// An answered request whose retirement takes longer than this is overdue:
    /// its publication has not settled and its capacity is still held.
    static let answeredUnretiredWarnAfter: Duration = .seconds(60)

    /// How many requests were answered before their publication and have not
    /// retired, and how long ago the oldest of them was answered.
    func answeredUnretiredSnapshot(now: ContinuousClock.Instant = .now) -> (count: Int, oldest: Duration?) {
        (answeredUnretired.count, answeredUnretired.values.min().map { $0.duration(to: now) })
    }

    /// Heartbeat cadence, on change only: one WARN when the oldest answered
    /// request passes `answeredUnretiredWarnAfter` without retiring, one INFO
    /// when none is past it again. A provider-log line and an `engine_health`
    /// event (`ssd_answered_unretired`, `ssd_answered_unretired_recovered`).
    func emitAnsweredUnretiredTransitionIfNeeded(now: ContinuousClock.Instant) {
        let (count, oldest) = answeredUnretiredSnapshot(now: now)
        let overdue = (oldest ?? .zero) >= Self.answeredUnretiredWarnAfter
        guard overdue != answeredUnretiredOverdueEmitted else { return }
        answeredUnretiredOverdueEmitted = overdue
        let oldestMs = oldest.map { Int($0 / .milliseconds(1)) } ?? 0
        if overdue {
            Self.earlyTerminalLogger.warning(
                "Early terminal: \(count) answered request(s) (\(modelId)) not retired; the oldest was answered \(oldestMs) ms ago and its checkpoint publication still holds its capacity")
        } else {
            Self.earlyTerminalLogger.info(
                "Early terminal: no answered request (\(modelId)) is past \(Int(Self.answeredUnretiredWarnAfter / .seconds(1))) s without retiring")
        }
        emit(EngineHealthEvent.make(
            severity: overdue ? .warn : .info,
            message: overdue
                ? "engine_v2: answered request not retired" : "engine_v2: answered requests retired",
            operation: overdue ? "ssd_answered_unretired" : "ssd_answered_unretired_recovered",
            model: modelId, kvBackend: kvBackendKind.rawValue,
            extra: ["answered_unretired": .int(count), "oldest_answered_unretired_ms": .int(oldestMs)]))
    }

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
