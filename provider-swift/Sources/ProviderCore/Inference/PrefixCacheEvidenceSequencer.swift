import Foundation

struct PrefixCacheV2EvidenceCallbacks: Sendable {
    let lookup: @Sendable (PrefixCacheLookupResult) -> Void
    let ready: @Sendable (PrefixCacheReadyResult) -> Void
    let terminal: @Sendable (OutboundMessage) -> Void
}

/// Serializes proof emission for one loaded model. A lock assigns enqueue IDs
/// synchronously, then this actor drains them in ID order: lookup is queued
/// before terminal by the finalizer, while racing ready callbacks are held until
/// lookup has been emitted.
actor PrefixCacheEvidenceSequencer {
    struct RequestStateSnapshot: Sendable, Equatable {
        let terminalSeen: Bool
        let readyBuffered: Bool
        let hasExpiry: Bool
    }

    private final class EnqueueGate: @unchecked Sendable {
        private let lock = NSLock()
        private var nextID: UInt64 = 1
        private var closed = false

        func claim() -> UInt64? {
            lock.withLock {
                guard !closed, nextID < UInt64.max else { return nil }
                defer { nextID += 1 }
                return nextID
            }
        }

        func close() {
            lock.withLock { closed = true }
        }
    }

    private struct Context: Sendable, Equatable {
        let requestID: String
        let nonce: String
        let capability: PrefixCacheV2Capability
        let forwardTerminal: Bool
    }

    private struct RequestState {
        let promptAnchor: PrefixCacheAnchor
        var highestReadyTokens = 0
        var pendingReady: PrefixCacheReadyResult?
        var terminalSeen = false
        var expiresAt: ContinuousClock.Instant?
    }

    private enum Command: Sendable {
        case lookup(Context, PrefixCacheLookupResult, SendHandle)
        case ready(Context, PrefixCacheReadyResult, SendHandle)
        case terminal(Context, OutboundMessage, SendHandle)
    }

    private static let terminalRetention: Duration = .seconds(125)
    private static let unresolvedPromptAnchor = PrefixCacheAnchor(
        chainHash: "", tokenCount: 0)
    private static let maxReceiptTokens: UInt64 = 1_000_000
    private static let maxStageMs = 600_000.0

    private let receiptTier: PrefixCacheTier
    private let capabilityProvider: @Sendable () -> PrefixCacheV2Capability?
    private let sequenceProvider: (@Sendable (String) -> UInt64?)?
    private nonisolated let enqueueGate = EnqueueGate()
    private var activeCapability: PrefixCacheV2Capability?
    private var nextSequence: UInt64 = 1
    private var nextCommandID: UInt64 = 1
    private var pendingCommands: [UInt64: Command] = [:]
    private var requests: [String: RequestState] = [:]

    init(cache: SSDPrefixCache) {
        self.init(source: cache)
    }

    init(source: any DurablePrefixCacheEvidenceSource) {
        self.receiptTier = .ssd
        self.capabilityProvider = { [weak source] in
            source?.prefixCacheV2Capability()
        }
        self.sequenceProvider = { [weak source] expectedEpoch in
            source?.takeNextPrefixCacheV2Sequence(expectedEpoch: expectedEpoch)
        }
    }

    init(
        tier: PrefixCacheTier = .ssd,
        capabilityProvider: @escaping @Sendable () -> PrefixCacheV2Capability?
    ) {
        self.receiptTier = tier
        self.capabilityProvider = capabilityProvider
        self.sequenceProvider = nil
    }

    nonisolated func shutdown() {
        enqueueGate.close()
    }

    nonisolated func callbacks(
        requestID: String,
        nonce: String,
        send: SendHandle,
        forwardTerminal: Bool = true,
        readyBoundaryMode: String? = nil
    ) -> PrefixCacheV2EvidenceCallbacks? {
        guard let capability = capabilityProvider() else { return nil }
        // The echo is absent on old coordinators. Local SSD reuse may still
        // proceed, but its checkpoint receipts must not be misread as legacy
        // durable coverage through the full prompt floor.
        if receiptTier == .ssd, let mode = capability.readyBoundaryMode, !mode.isEmpty {
            guard mode == PrefixCacheV2Capability.checkpointBoundaryMode,
                readyBoundaryMode == mode else { return nil }
        }
        let context = Context(
            requestID: requestID,
            nonce: nonce,
            capability: capability,
            forwardTerminal: forwardTerminal)
        return PrefixCacheV2EvidenceCallbacks(
            lookup: { [weak self] result in
                self?.enqueue(.lookup(context, result, send))
            },
            ready: { [weak self] result in
                self?.enqueue(.ready(context, result, send))
            },
            terminal: { [weak self] message in
                self?.enqueue(.terminal(context, message, send))
            })
    }

    private nonisolated func enqueue(_ command: Command) {
        guard let id = enqueueGate.claim() else { return }
        Task { [weak self] in
            await self?.receive(id: id, command: command)
        }
    }

    private func receive(id: UInt64, command: Command) {
        pendingCommands[id] = command
        while let next = pendingCommands.removeValue(forKey: nextCommandID) {
            sweepExpired(now: .now)
            nextCommandID += 1
            switch next {
            case .lookup(let context, let result, let send):
                handleLookup(context, result: result, send: send)
            case .ready(let context, let result, let send):
                handleReady(context, result: result, send: send)
            case .terminal(let context, let message, let send):
                handleTerminal(context, message: message, send: send)
            }
        }
    }

    private func sweepExpired(now: ContinuousClock.Instant) {
        let expired = requests.compactMap { nonce, state -> String? in
            guard let expiresAt = state.expiresAt, expiresAt <= now else {
                return nil
            }
            return nonce
        }
        for nonce in expired {
            requests.removeValue(forKey: nonce)
        }
    }

    func requestStateSnapshotForTesting(nonce: String) -> RequestStateSnapshot? {
        requests[nonce].map {
            RequestStateSnapshot(
                terminalSeen: $0.terminalSeen,
                readyBuffered: $0.pendingReady != nil,
                hasExpiry: $0.expiresAt != nil)
        }
    }

    func sweepExpiredForTesting(after duration: Duration) -> Int {
        sweepExpired(now: ContinuousClock.now.advanced(by: duration))
        return requests.count
    }

    private func current(_ context: Context) -> Bool {
        guard let live = capabilityProvider() else {
            activeCapability = nil
            nextSequence = 1
            requests.removeAll(keepingCapacity: false)
            return false
        }
        if live != activeCapability {
            activeCapability = live
            nextSequence = 1
            requests.removeAll(keepingCapacity: false)
        }
        return live == context.capability
    }

    private func handleLookup(
        _ context: Context,
        result: PrefixCacheLookupResult,
        send: SendHandle
    ) {
        guard current(context) else { return }
        let existing = requests[context.nonce]
        guard existing == nil || existing?.promptAnchor.chainHash.isEmpty == true,
            result.tier == receiptTier,
            valid(stageMs: result.stageMs),
            let promptAnchor = result.promptAnchor,
            valid(anchor: promptAnchor, capability: context.capability)
        else { return }

        if result.outcome == .hit {
            if receiptTier == .ssd,
                context.capability.readyBoundaryMode == PrefixCacheV2Capability.checkpointBoundaryMode,
                (result.requiredRecomputeTokens != 0 || (result.stageMs ?? 0) <= 0) { return }
            guard let matched = result.matchedAnchor,
                valid(anchor: matched, capability: context.capability),
                matched.tokenCount <= promptAnchor.tokenCount,
                matched.tokenCount <= UInt64(Int.max)
            else { return }
            let matchedTokens = Int(matched.tokenCount)
            guard result.requiredRecomputeTokens <= matchedTokens,
                result.prefillTokensSaved
                    == matchedTokens - result.requiredRecomputeTokens
            else { return }
        } else {
            guard result.matchedAnchor == nil,
                result.requiredRecomputeTokens == 0,
                result.prefillTokensSaved == 0
            else { return }
        }
        guard let sequence = takeSequence(expectedEpoch: context.capability.cacheEpoch) else {
            return
        }
        send.send(.prefixCacheLookupV2(ProviderMessage.PrefixCacheLookupV2(
            requestId: context.requestID,
            cacheReceiptNonce: context.nonce,
            modelId: context.capability.modelId,
            modelAggregateHash: context.capability.modelAggregateHash,
            promptContractId: context.capability.promptContractId,
            cacheEpoch: context.capability.cacheEpoch,
            cacheSeq: sequence,
            promptAnchor: promptAnchor,
            matchedAnchor: result.matchedAnchor,
            outcome: result.outcome,
            tier: result.tier,
            requiredRecomputeTokens: UInt64(result.requiredRecomputeTokens),
            expectedPrefillTokensSaved: UInt64(result.prefillTokensSaved),
            stageMs: result.stageMs)))

        let pending = existing?.pendingReady
        var resolved = RequestState(promptAnchor: promptAnchor)
        // A lookup command can arrive after a ready/terminal race. Preserve a
        // terminal tombstone's deadline while replacing its unresolved anchor;
        // a pre-lookup ready without a terminal becomes ordinary live state.
        if existing?.terminalSeen == true {
            resolved.terminalSeen = true
            resolved.expiresAt = existing?.expiresAt
                ?? ContinuousClock.now.advanced(by: Self.terminalRetention)
        }
        requests[context.nonce] = resolved
        if let pending {
            handleReady(context, result: pending, send: send)
        }
    }

    private func handleReady(
        _ context: Context,
        result: PrefixCacheReadyResult,
        send: SendHandle
    ) {
        guard current(context),
            result.tier == receiptTier,
            valid(stageMs: result.stageMs),
            let finalAnchor = result.finalAnchor,
            valid(anchor: finalAnchor, capability: context.capability),
            finalAnchor.tokenCount <= UInt64(Int.max),
            result.requiredRecomputeTokens <= Int(finalAnchor.tokenCount),
            result.expectedPrefillTokensSaved
                == Int(finalAnchor.tokenCount) - result.requiredRecomputeTokens
        else { return }
        guard var state = requests[context.nonce] else {
            // Donation can settle before the lookup command reaches this actor.
            // Keep only the furthest publication for bounded buffering. An
            // expiry is mandatory: a lookup from another tier is ignored,
            // so a late publication must not create immortal state.
            requests[context.nonce] = RequestState(
                promptAnchor: Self.unresolvedPromptAnchor,
                pendingReady: result,
                expiresAt: ContinuousClock.now.advanced(by: Self.terminalRetention))
            return
        }
        guard !state.promptAnchor.chainHash.isEmpty else {
            if finalAnchor.tokenCount > (state.pendingReady?.finalAnchor?.tokenCount ?? 0) {
                state.pendingReady = result
                requests[context.nonce] = state
            }
            return
        }
        let explicitCheckpoints = receiptTier == .memory
            || context.capability.readyBoundaryMode == PrefixCacheV2Capability.checkpointBoundaryMode
        guard (explicitCheckpoints || finalAnchor.tokenCount >= state.promptAnchor.tokenCount),
            finalAnchor.tokenCount > UInt64(state.highestReadyTokens),
            receiptTier != .ssd || !explicitCheckpoints
                || (result.requiredRecomputeTokens == 0 && (result.stageMs ?? 0) > 0)
        else { return }
        let anchors: [PrefixCacheAnchor]
        if explicitCheckpoints {
            anchors = result.readyAnchors
            guard !anchors.isEmpty, anchors.count <= 16,
                anchors.last == finalAnchor,
                anchors.allSatisfy({
                    valid(anchor: $0, capability: context.capability)
                        && $0.tokenCount <= state.promptAnchor.tokenCount
                }),
                zip(anchors, anchors.dropFirst()).allSatisfy({ pair in
                    pair.0.tokenCount < pair.1.tokenCount
                })
            else { return }
        } else {
            anchors = finalAnchor == state.promptAnchor
                ? [state.promptAnchor] : [state.promptAnchor, finalAnchor]
        }
        guard let sequence = takeSequence(expectedEpoch: context.capability.cacheEpoch) else { return }
        send.send(.prefixCacheReadyV2(ProviderMessage.PrefixCacheReadyV2(
            requestId: context.requestID,
            cacheReceiptNonce: context.nonce,
            modelId: context.capability.modelId,
            modelAggregateHash: context.capability.modelAggregateHash,
            promptContractId: context.capability.promptContractId,
            cacheEpoch: context.capability.cacheEpoch,
            cacheSeq: sequence,
            tier: result.tier,
            readyAnchors: anchors,
            requiredRecomputeTokens: UInt64(result.requiredRecomputeTokens),
            expectedPrefillTokensSaved: UInt64(result.expectedPrefillTokensSaved),
            stageMs: result.stageMs)))
        state.highestReadyTokens = Int(finalAnchor.tokenCount)
        state.pendingReady = nil
        requests[context.nonce] = state
    }

    private func handleTerminal(
        _ context: Context,
        message: OutboundMessage,
        send: SendHandle
    ) {
        if current(context) {
            let expiry = ContinuousClock.now.advanced(by: Self.terminalRetention)
            if var state = requests[context.nonce] {
                state.terminalSeen = true
                state.expiresAt = expiry
                requests[context.nonce] = state
            } else {
                // A missing or other-tier lookup creates no resolved state.
                // Keep a bounded tombstone so a late publication cannot
                // recreate an expiry-less placeholder after terminal.
                requests[context.nonce] = RequestState(
                    promptAnchor: Self.unresolvedPromptAnchor,
                    terminalSeen: true,
                    expiresAt: expiry)
            }
        }
        if context.forwardTerminal { send.send(message) }
    }

    private func takeSequence(expectedEpoch: String) -> UInt64? {
        if let sequenceProvider {
            return sequenceProvider(expectedEpoch)
        }
        guard nextSequence > 0, nextSequence < UInt64.max else { return nil }
        defer { nextSequence += 1 }
        return nextSequence
    }

    private func valid(
        anchor: PrefixCacheAnchor,
        capability: PrefixCacheV2Capability
    ) -> Bool {
        capability.blockSize > 0
            && anchor.tokenCount > 0
            && anchor.tokenCount <= Self.maxReceiptTokens
            && anchor.tokenCount % UInt64(capability.blockSize) == 0
            && anchor.chainHash.utf8.count == 64
            && anchor.chainHash.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }

    private func valid(stageMs: Double?) -> Bool {
        guard let stageMs else { return true }
        return stageMs.isFinite && stageMs >= 0 && stageMs <= Self.maxStageMs
    }
}
