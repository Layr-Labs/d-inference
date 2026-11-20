import Foundation
import MLXLMCommon

// MARK: - Per-request usage signal

/// Thread-safe, set-once-read-late box for a request's terminal usage detail,
/// exact matched stop sequence, and final lookup receipt. One instance per request
/// (created by the coordinator inference handler only when the slot serves
/// via the v2 engine); finalized by terminal usage or by the precise
/// pre-terminal failure path. On success the pump records BEFORE yielding
/// terminal events, so the trailing usage frame always observes the write.
public final class EngineV2RequestUsageSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var _matchedStopSequence: String?
    private var _answerFinished = false
    private var _prefixCacheHitTokens: Int?
    private var _prefixCachePrefillTokensSaved: Int?
    private var _stageResult: SSDPrefixCacheStageResult?
    private var _lookupResult: PrefixCacheLookupResult?
    private var _cacheDisabled = false
    /// A positive, advisory resident probe caused the bridge to skip SSD
    /// staging. If the page claim later races with allocator reuse, classify
    /// the cold fallback as memory rather than inventing an SSD miss.
    private var _residentCandidateSeen = false
    private let _withheldReasoning = ResponseTextBuffer()
    private var _toolCalls: ToolCallTally?
    private var _firstWithheldOutputAt: ContinuousClock.Instant?
    private var didEmitLookup = false
    /// Armed before the pump task can run; only the pump may resolve it.
    /// Waiters exist only on canceled settlement, never on ordinary decode.
    private var terminalObservationStarted = false
    private var terminalObservationPending = false
    private var terminalWaiters: [CheckedContinuation<Void, Never>] = []
    private var residentProof: ResidentPrefixCachePromptProof?
    private let onLookupResolved: (@Sendable (PrefixCacheLookupResult) -> Void)?
    let onCacheReady: (@Sendable (PrefixCacheReadyResult) -> Void)?

    public init(
        onLookupResolved: (@Sendable (PrefixCacheLookupResult) -> Void)? = nil,
        onCacheReady: (@Sendable (PrefixCacheReadyResult) -> Void)? = nil
    ) {
        self.onLookupResolved = onLookupResolved
        self.onCacheReady = onCacheReady
    }

    func beginTerminalObservation() {
        lock.withLock {
            precondition(!terminalObservationStarted, "usage signal belongs to one request")
            terminalObservationStarted = true
            terminalObservationPending = true
        }
    }

    /// The owner's request submitted again after the engine ended it before
    /// admitting it (`EngineV2Bridge.submittingOwnerRequest`): the earlier
    /// attempt's pump finishes its terminal observation and resource cleanup
    /// first, then the next attempt's pump observes its own. At once when the
    /// earlier attempt never reached a pump.
    func awaitEarlierAttempt() async {
        await waitForTerminalObservation()
        lock.withLock {
            guard terminalObservationStarted else { return }
            // The earlier attempt ended before admission: nothing it looked up or staged was used.
            terminalObservationStarted = false
            _stageResult = nil
            _lookupResult = nil
            _residentCandidateSeen = false
            residentProof = nil
            _prefixCacheHitTokens = nil
            _prefixCachePrefillTokensSaved = nil
            _toolCalls = nil
        }
    }

    /// Called after lookup delivery and the pump's resource cleanup, including
    /// teardown without a native terminal. Resume outside the signal lock.
    func completeTerminalObservation() {
        let waiters = lock.withLock {
            terminalObservationPending = false
            let pending = terminalWaiters
            terminalWaiters.removeAll(keepingCapacity: false)
            return pending
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Cancellation of the consumer must not skip native settlement. The
    /// owning pump is independent of that task and resolves on native finish
    /// or shutdown/stream teardown. A request that never reached a pump has
    /// no observation to await. First content cannot precede pump registration.
    func waitForTerminalObservation() async {
        await withCheckedContinuation { continuation in
            let waiting = lock.withLock {
                guard terminalObservationPending else { return false }
                terminalWaiters.append(continuation)
                return true
            }
            if !waiting { continuation.resume() }
        }
    }

    /// Record the engine-reported prefix-cache hit tokens for this request.
    func record(
        usage: CBv2Usage,
        fallbackTier: PrefixCacheTier = .memory
    ) {
        let resolved: PrefixCacheLookupResult? = lock.withLock {
            // `prefixCacheHitTokens` is the pre-v1 compatibility alias. Old
            // scripted engines may set only that field, so let it raise (never
            // lower) the richer counts.
            let matched = max(0, usage.prefixCacheMatchedTokens, usage.prefixCacheHitTokens)
            let saved = max(0, usage.prefixCachePrefillTokensSaved, usage.prefixCacheHitTokens)
            let engineOutcome: CBv2PrefixCacheOutcome =
                usage.prefixCacheOutcome == .disabled && usage.prefixCacheHitTokens > 0
                ? .hit : usage.prefixCacheOutcome
            // EngineV2 reports the tier that ACTUALLY won adoption. This is
            // essential when resident L1 and staged SSD L2 both match: SSD
            // may have completed its pre-submit read, but a zero-copy L1 win
            // must be billed/telemetried as memory and must not mint a durable
            // holder receipt. nil preserves scripted/older-engine fallback.
            let engineTier: PrefixCacheTier? = switch usage.prefixCacheTier {
            case .resident, .memorySnapshot: .memory
            case .snapshot: .ssd
            case nil: nil
            }
            // Client-facing `cached_tokens` (standalone server usage and the
            // provider SSE splice) means prompt tokens actually reused. A
            // matched checkpoint whose adoption failed or was skipped reused
            // nothing; the resolved lookup below reports it the same way.
            _prefixCacheHitTokens = engineOutcome == .hit ? matched : 0
            _prefixCachePrefillTokensSaved = saved
            if _cacheDisabled { return nil }
            let unresolvedTier: PrefixCacheTier =
                _residentCandidateSeen ? .memory : fallbackTier
            switch engineOutcome {
            case .hit:
                if engineTier == .memory {
                    _lookupResult = PrefixCacheLookupResult(
                        outcome: .hit,
                        tier: .memory,
                        cachedTokens: matched,
                        prefillTokensSaved: saved,
                        requiredRecomputeTokens: max(0, matched - saved))
                } else if let stage = _stageResult {
                    _lookupResult = stage.resolved(
                        actualCachedTokens: matched,
                        actualPrefillTokensSaved: saved)
                } else {
                    _lookupResult = PrefixCacheLookupResult(
                        outcome: .hit,
                        tier: engineTier ?? unresolvedTier,
                        cachedTokens: matched,
                        prefillTokensSaved: saved)
                }
            case .miss:
                if let stage = _stageResult {
                    _lookupResult = stage.resolved(actualCachedTokens: 0)
                } else {
                    _lookupResult = PrefixCacheLookupResult(
                        outcome: .missAbsent, tier: unresolvedTier)
                }
            case .skippedCapacity:
                _lookupResult = _stageResult?.resolved(failure: .capacity)
                    ?? PrefixCacheLookupResult(
                        outcome: .skippedCapacity, tier: unresolvedTier)
            case .skippedPolicy, .disabled, .adoptionFailed:
                _lookupResult = _stageResult?.resolved(failure: .policy)
                    ?? PrefixCacheLookupResult(
                        outcome: .skippedPolicy, tier: unresolvedTier)
            }
            if let result = _lookupResult, result.tier == .memory, let residentProof {
                _lookupResult = residentProof.resolve(result)
            }
            guard !didEmitLookup, let result = _lookupResult else { return nil }
            didEmitLookup = true
            return result
        }
        if let resolved { onLookupResolved?(resolved) }
    }

    /// Compatibility helper for scripted tests/older callers whose usage did
    /// not yet expose the richer engine outcome.
    func record(prefixCacheHitTokens: Int) {
        let tokens = max(0, prefixCacheHitTokens)
        record(
            usage: CBv2Usage(
                promptTokens: 0,
                completionTokens: 0,
                prefixCacheHitTokens: tokens,
                prefixCacheOutcome: tokens > 0 ? .hit : .miss,
                prefixCacheMatchedTokens: tokens,
                prefixCachePrefillTokensSaved: tokens))
    }

    func record(stageResult: SSDPrefixCacheStageResult) {
        lock.withLock { _stageResult = stageResult }
    }

    func recordResidentPrompt(_ proof: ResidentPrefixCachePromptProof) {
        lock.withLock { residentProof = proof }
    }

    func recordResidentPublication(checkpointTokens: [Int]) {
        let proof = lock.withLock { residentProof }
        if let ready = proof?.publication(checkpointTokens: checkpointTokens) {
            onCacheReady?(ready)
        }
    }

    func recordResidentPrefixCandidate() {
        lock.withLock { _residentCandidateSeen = true }
    }

    func finalizeLookup(
        failure: PrefixCacheLookupFailureClass,
        fallbackTier: PrefixCacheTier
    ) {
        let resolved: PrefixCacheLookupResult? = lock.withLock {
            guard !didEmitLookup else { return nil }
            let unresolvedTier: PrefixCacheTier =
                _residentCandidateSeen ? .memory : fallbackTier
            let result = _stageResult?.resolved(failure: failure)
                ?? PrefixCacheLookupResult(
                    outcome: failure == .capacity ? .skippedCapacity : .skippedPolicy,
                    tier: unresolvedTier)
            let resolved = result.tier == .memory
                ? (residentProof?.resolve(result) ?? result) : result
            _lookupResult = resolved
            didEmitLookup = true
            return resolved
        }
        if let resolved { onLookupResolved?(resolved) }
    }

    func recordCacheDisabled(tier: PrefixCacheTier?) {
        let resolved: PrefixCacheLookupResult? = lock.withLock {
            _cacheDisabled = true
            _lookupResult = PrefixCacheLookupResult(
                outcome: .skippedPolicy, tier: tier)
            guard !didEmitLookup, let result = _lookupResult else { return nil }
            didEmitLookup = true
            return result
        }
        if let resolved { onLookupResolved?(resolved) }
    }

    func record(matchedStopSequence: String?) {
        guard let matchedStopSequence, !matchedStopSequence.isEmpty else { return }
        lock.withLock { _matchedStopSequence = matchedStopSequence }
    }

    public var matchedStopSequence: String? {
        lock.withLock { _matchedStopSequence }
    }

    /// The engine finished the answer on its own (stop or length), before any
    /// cancel could. Recorded before the terminal events are yielded; the
    /// frames loop may still be sending the answer when a cancel lands.
    func recordAnswerFinished() {
        lock.withLock { _answerFinished = true }
    }

    public var answerFinished: Bool {
        lock.withLock { _answerFinished }
    }

    /// Reasoning generated for a request that asked not to receive it. It is
    /// still generated work: the provider frames loop counts it toward
    /// `reasoning_tokens`, and its arrival ends the pre-content interval.
    /// Request-local plaintext; never telemetry, logs or the response hash.
    /// Recorded before any later event is yielded, so a frame produced after
    /// it always observes the write.
    func recordWithheldReasoning(_ text: String) {
        guard !text.isEmpty else { return }
        lock.withLock {
            if _firstWithheldOutputAt == nil { _firstWithheldOutputAt = .now }
            _withheldReasoning.append(text)
        }
    }

    /// The calls a finished response returned. Counts only: never a name,
    /// arguments or schema. Recorded before the terminal events are yielded.
    func recordToolCalls(_ tally: ToolCallTally) {
        guard tally.returned > 0 else { return }
        lock.withLock { _toolCalls = tally }
    }

    public var toolCalls: ToolCallTally? {
        lock.withLock { _toolCalls }
    }

    /// Answer output was generated on a GLM request that may withhold it until
    /// it validates (a JSON `response_format`, and forced calls). Forced calls
    /// to a client that streams (`ToolStreamPreparation.streamsGLMCalls`) are
    /// recorded too, although they leave as generated: the interval then ends
    /// at the first generated token, not the first frame on the wire. Like
    /// withheld reasoning, its generation ends the pre-content interval; it is
    /// never counted as reasoning. Recorded before any later event is yielded.
    func recordWithheldOutput() {
        lock.withLock {
            if _firstWithheldOutputAt == nil { _firstWithheldOutputAt = .now }
        }
    }

    /// Tests only: a `String` copy of the withheld reasoning.
    var withheldReasoning: String {
        lock.withLock { _withheldReasoning.withText { $0 } }
    }

    var hasWithheldReasoning: Bool {
        lock.withLock { !_withheldReasoning.isEmpty }
    }

    /// Appends the withheld reasoning to `buffer` without a `String` copy.
    func appendWithheldReasoning(to buffer: ResponseTextBuffer) {
        lock.withLock { buffer.append(contentsOf: _withheldReasoning) }
    }

    /// When the first withheld output, reasoning or answer, was generated;
    /// nil while none was.
    var firstWithheldOutputAt: ContinuousClock.Instant? {
        lock.withLock { _firstWithheldOutputAt }
    }

    /// Engine-reported prompt tokens whose KV was adopted from the prefix
    /// cache (0 on a miss). nil until the request reached its terminal.
    public var prefixCacheHitTokens: Int? {
        lock.withLock { _prefixCacheHitTokens }
    }

    public var prefixCachePrefillTokensSaved: Int? {
        lock.withLock { _prefixCachePrefillTokensSaved }
    }

    public var lookupResult: PrefixCacheLookupResult? {
        lock.withLock { _lookupResult }
    }
}

/// A finished response's tool calls, for its profile: how many it returned,
/// and how many of those break the request's declaration (returned as
/// generated: an undeclared function or arguments the declared schema
/// refuses, `ToolConstraintValidation.breaksDeclaration`).
public struct ToolCallTally: Sendable, Equatable {
    public let returned: Int
    public let breakingDeclaration: Int

    public init(returned: Int, breakingDeclaration: Int) {
        self.returned = returned
        self.breakingDeclaration = breakingDeclaration
    }
}
