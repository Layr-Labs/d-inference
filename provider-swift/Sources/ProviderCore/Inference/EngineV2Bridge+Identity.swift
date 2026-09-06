// Provider request IDs and deterministic seeded engine IDs.

import Foundation
import MLXLMCommon
import ProviderCoreFoundation

extension EngineV2Bridge {
    // MARK: - Engine request-id minting

    /// Tag bit for (seed, prompt)-derived engine ids. Keeps the seeded id
    /// family disjoint from the monotonic counter (which starts at 1 and can
    /// never reach 2^63 at any real submit rate), so a derived id can only
    /// ever collide with another SEEDED id — and then only for an identical
    /// (seed, prompt) pair, which `mintEngineRequestId` guards against.
    static let seededIdTagBit: UInt64 = 1 << 63

    /// Deterministic engine-id for a seeded submission: a SplitMix64 chain
    /// over (seed, promptTokens…), tagged into the seeded id family.
    ///
    /// WHY (round-2 PR#499 P2): the v2 sampler's RNG key is
    /// (seed, requestID.raw, stepIndex) — `SamplerV2.mix` — so `seed` only
    /// reproduces output if the request id is itself a pure function of the
    /// request. Deriving it from (seed, prompt) makes same-seed + same-prompt
    /// submissions sample identically at B=1 regardless of prior traffic,
    /// while different prompts/seeds still get distinct RNG streams.
    ///
    /// Deterministic across processes (no `Hasher` seed), mirroring the
    /// engine sampler's own SplitMix64 keying family.
    static func stableSeededRawId(seed: UInt64, promptTokens: [Int]) -> UInt64 {
        var hash = splitmix64(seed)
        for token in promptTokens {
            hash = splitmix64(hash ^ UInt64(bitPattern: Int64(token)))
        }
        return hash | seededIdTagBit
    }

    /// SplitMix64 finalizer (public-domain constants).
    static func splitmix64(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Mint the engine id for a submission. Seeded requests get the stable
    /// (seed, prompt)-derived id; everything else gets the monotonic counter
    /// (`&+` wrap: 2^63 ids is unreachable, but the overflow is defined).
    ///
    /// Collision guard: an IDENTICAL seeded request that is LIVE or awaiting
    /// async atomic admission would collide inside the engine's per-request
    /// maps, so the derived id falls back to a fresh monotonic id. DOCUMENTED LIMITS of seeded
    /// reproducibility: (a) submissions that overlap their own duplicate
    /// in-flight lose the stable id (this fallback); (b) under batching the
    /// contract is best-effort — the RNG key itself is batch-invariant, but
    /// non-deterministic kernel scheduling can still perturb floating-point
    /// reductions across different batch compositions.
    ///
    /// Its result is inserted into `pendingEngineIDs` in the same synchronous
    /// stretch. That reservation spans the async engine call and closes the
    /// actor-reentrancy gap before `idMap` registration.
    func mintEngineRequestId(seed: UInt64?, promptTokens: [Int]) -> CBv2RequestID {
        if let seed {
            let stable = CBv2RequestID(
                Self.stableSeededRawId(seed: seed, promptTokens: promptTokens))
            // O(live requests) scan (≤ engine concurrency + waiting cap);
            // only taken on seeded submissions.
            if !idMap.values.contains(stable), !pendingEngineIDs.contains(stable) {
                return stable
            }
        }
        let fresh = CBv2RequestID(nextRawId)
        nextRawId &+= 1
        return fresh
    }

    /// Monotonic correlation identity for one receipt-enabled submission.
    /// It is deliberately independent of `mintEngineRequestId`: seeded engine
    /// ids may repeat after terminal for deterministic sampling, while receipt
    /// callbacks remain retained for the coordinator settlement window.
    func mintPrefixCacheReceiptID() -> CBv2RequestID {
        let id = CBv2RequestID(nextPrefixCacheReceiptRawId)
        nextPrefixCacheReceiptRawId &+= 1
        return id
    }

    // MARK: - Request-id validation

    /// Return a request-id safe to use as a dictionary key and cancel
    /// correlation handle. A caller-supplied id is accepted verbatim only
    /// when it is non-empty, at most `maxRequestIdLength`, and printable
    /// (no ASCII control chars); otherwise — and when nil — a fresh
    /// `req-<uuid-prefix>` is generated. Pure/static so it is unit-testable.
    static func normalizedRequestId(_ requestId: String?) -> String {
        if let requestId, isValidRequestId(requestId) { return requestId }
        return "req-\(UUID().uuidString.prefix(12))"
    }

    /// A request-id is valid when non-empty, within the length cap, and free
    /// of ASCII control characters (`< 0x20` or DEL `0x7f`).
    static func isValidRequestId(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= maxRequestIdLength else { return false }
        return !id.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }
}
