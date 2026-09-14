import Foundation
import MLXLMCommon

/// Connection advertisements reference this slot-lifetime capability. Routine
/// LRU eviction does not rotate the slot epoch: coordinator holders are advisory,
/// expire after 30 seconds, and an actual miss invalidates matching evidence.
public final class ResidentPrefixCacheEvidence: @unchecked Sendable {
    private final class WeakSignal {
        weak var value: EngineV2RequestUsageSignal?
        init(_ value: EngineV2RequestUsageSignal) { self.value = value }
    }

    private let lock = NSLock()
    private let identity: PrefixCacheV2Capability
    private var closed = false
    private var requests: [CBv2RequestID: WeakSignal] = [:]

    public init?(modelId: String, modelAggregateHash: String, promptContractID: String) {
        func validHash(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
        }
        guard !modelId.isEmpty, validHash(modelAggregateHash), validHash(promptContractID) else {
            return nil
        }
        self.identity = PrefixCacheV2Capability(
            modelId: modelId,
            modelAggregateHash: modelAggregateHash,
            promptContractId: promptContractID,
            blockHashVersion: CBv2BlockHasher.version,
            blockSize: UInt32(CBv2BlockHasher.defaultBlockSize),
            cacheEpoch: UUID().uuidString.lowercased(),
            enabled: true,
            ready: true)
    }

    func capability() -> PrefixCacheV2Capability? {
        lock.withLock { closed ? nil : identity }
    }

    func promptProof(tokens: [Int], scope: String) -> ResidentPrefixCachePromptProof? {
        guard capability() != nil, !scope.isEmpty,
            tokens.count <= 1_000_000,
            tokens.allSatisfy({ $0 >= 0 && UInt64($0) <= UInt64(UInt32.max) })
        else { return nil }
        let hasher = CBv2BlockHasher(promptContractID: identity.promptContractId, scopeID: scope)
        let hashes = hasher.chainHashes(tokens: tokens, maxBlocks: hasher.maxLookupBlocks(tokenCount: tokens.count))
        guard !hashes.isEmpty else { return nil }
        return ResidentPrefixCachePromptProof(anchors: hashes.enumerated().map { index, hash in
            PrefixCacheAnchor(
                chainHash: hash.hexString,
                tokenCount: UInt64((index + 1) * hasher.blockSize))
        })
    }

    /// The receipt identity is submission-unique even when a seeded request
    /// deliberately reuses its engine sampling ID.
    func register(receiptID: CBv2RequestID, signal: EngineV2RequestUsageSignal) {
        lock.withLock {
            guard !closed else { return }
            requests[receiptID] = WeakSignal(signal)
        }
    }

    func publish(receiptID: CBv2RequestID, checkpointTokens: [Int]) {
        let signal = lock.withLock { requests.removeValue(forKey: receiptID)?.value }
        signal?.recordResidentPublication(checkpointTokens: checkpointTokens)
    }

    func discard(receiptID: CBv2RequestID) {
        _ = lock.withLock { requests.removeValue(forKey: receiptID) }
    }

    func close() {
        lock.withLock {
            closed = true
            requests.removeAll(keepingCapacity: false)
        }
    }
}

/// Coordinator-compatible 256-token chained anchors, independent of physical
/// page hashes. Publication selects only endpoints actually reusable by the bank.
struct ResidentPrefixCachePromptProof: Sendable {
    let anchors: [PrefixCacheAnchor]

    func resolve(_ result: PrefixCacheLookupResult) -> PrefixCacheLookupResult {
        guard let prompt = anchors.last else { return result }
        let blockSize = CBv2BlockHasher.defaultBlockSize
        let matchedBlocks = min(result.cachedTokens / blockSize, anchors.count)
        let matched = result.outcome == .hit && matchedBlocks > 0 ? anchors[matchedBlocks - 1] : nil
        let recompute = matched.map { min(Int($0.tokenCount), result.requiredRecomputeTokens) } ?? 0
        return PrefixCacheLookupResult(
            outcome: result.outcome == .hit && matched == nil ? .skippedPolicy : result.outcome,
            tier: .memory,
            cachedTokens: matched.map { Int($0.tokenCount) } ?? 0,
            prefillTokensSaved: matched.map { Int($0.tokenCount) - recompute } ?? 0,
            stageMs: 0,
            promptAnchor: prompt,
            matchedAnchor: matched,
            requiredRecomputeTokens: recompute)
    }

    func publication(checkpointTokens: [Int]) -> PrefixCacheReadyResult? {
        let blockSize = CBv2BlockHasher.defaultBlockSize
        let positions = Set(checkpointTokens.filter {
            $0 > 0 && $0 % blockSize == 0 && $0 / blockSize <= anchors.count
        }).sorted()
        // Preserve the earliest shared checkpoint and the deepest 15 when a
        // long prompt has more endpoints than the bounded wire receipt allows.
        let bounded = positions.count <= 16 ? positions : Array(positions.prefix(1)) + Array(positions.suffix(15))
        let published = bounded.map { anchors[$0 / blockSize - 1] }
        guard let final = published.last else { return nil }
        return PrefixCacheReadyResult(
            readyTokens: Int(final.tokenCount),
            requiredRecomputeTokens: 0,
            expectedPrefillTokensSaved: Int(final.tokenCount),
            tier: .memory,
            stageMs: 0,
            finalAnchor: final,
            readyAnchors: published)
    }
}
