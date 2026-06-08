/// PrefixDigest — exact-checkpoint keys for the prefix KV cache.
///
/// A "checkpoint" is a fixed prefix length (256, 512, 1024, … by
/// default — design O9). For a prompt's token-ID array we compute the
/// SHA-256 of the first `c` tokens at each checkpoint `c ≤ count`. Two
/// requests sharing a system prompt produce identical digests at every
/// checkpoint that lands within the shared region, so an exact-
/// checkpoint lookup (design §4.4) can find the longest cached prefix
/// without a full longest-common-prefix scan.
///
/// The digests at successive checkpoints are genuine prefixes of one
/// another: they are computed in a single pass by snapshotting the
/// rolling SHA-256 state at each boundary, so the checkpoint-`c` digest
/// equals an independent hash of the first `c` tokens. (Verified in
/// PrefixDigestTests.)
///
/// Tokens are hashed as little-endian Int64 after a fixed domain-
/// separation prefix, so these digests can't collide with other SHA
/// uses and are stable across machines (the same prompt → the same
/// digest everywhere).

import CryptoKit
import Foundation

public enum PrefixDigest {

    /// Default checkpoint boundaries (design O9). Powers of two from 256
    /// to 8192 give predictable exact-match points: a 1500-token prompt
    /// hits the 1024 checkpoint and reuses 1024 of its prefill.
    public static let defaultCheckpoints: [Int] = [256, 512, 1024, 2048, 4096, 8192]

    /// Checkpoint boundaries usable by a model whose smallest sliding-window
    /// attention layer retains `slidingWindow` tokens. A whole-cache
    /// checkpoint snapshot at length L only reproduces the full prefix when
    /// every sliding layer still holds all L tokens, i.e. `L <= slidingWindow`
    /// (a rotating window has physically discarded tokens older than its
    /// window). So we keep only boundaries `<= slidingWindow`, and add the
    /// window itself as the largest usable checkpoint.
    ///
    /// `slidingWindow <= 0` (no sliding layers / unknown) ⇒ the defaults
    /// unchanged. Example: Gemma-4 (512) → [256, 512]; GPT-OSS (128) →
    /// [64, 128] (so it gets *some* usable checkpoint despite the tiny
    /// window — see docs/ssd-kv-cache-hybrid-models.md §3).
    public static func checkpoints(forSlidingWindow slidingWindow: Int) -> [Int] {
        guard slidingWindow > 0 else { return defaultCheckpoints }
        var usable = defaultCheckpoints.filter { $0 <= slidingWindow }
        if usable.last != slidingWindow {
            usable.append(slidingWindow)
        }
        // For small windows the defaults may all be filtered out; ensure at
        // least one sub-window boundary so the model gets a checkpoint.
        if usable.first ?? Int.max > slidingWindow / 2, slidingWindow / 2 >= 1 {
            usable.insert(slidingWindow / 2, at: 0)
        }
        return Array(Set(usable)).filter { $0 > 0 }.sorted()
    }

    /// Coarse past-window ladder (TB-016 sub-feature A). Extends the
    /// fine in-window ladder to 32k for PROVEN model families (Gemma)
    /// where KV restore past the sliding window is bit-exact. Ceiling:
    /// 32768 (human decision, balancing reuse vs write amplification).
    static let pastWindowLadder = [2048, 4096, 8192, 16384, 32768]

    /// NEW overload for TB-016: returns the in-window ladder PLUS the
    /// coarse past-window tail when `pastWindowProven` is true AND
    /// `maxContext > inWindow.last`. If `maxContext == 0` OR
    /// `pastWindowProven == false`, returns the unchanged in-window
    /// ladder (safe; GPT-OSS & unknown models keep today's behavior).
    ///
    /// The caller wires `pastWindowProven` from
    /// `PrefixCachePastWindow.isProven(arch:)` (true only for Gemma),
    /// and `maxContext` from the model's `architecture.maxContextLength`.
    ///
    /// IMPORTANT: This overload does NOT change the existing
    /// `checkpoints(forSlidingWindow:)` — that stays within-window-only.
    /// Existing callers and tests remain byte-identical.
    public static func checkpoints(
        forSlidingWindow window: Int,
        maxContext: Int,
        pastWindowProven: Bool
    ) -> [Int] {
        let inWindow = checkpoints(forSlidingWindow: window)
        guard pastWindowProven, maxContext > (inWindow.last ?? 0) else {
            return inWindow
        }
        let tail = pastWindowLadder.filter { $0 > (inWindow.last ?? 0) && $0 <= maxContext }
        return Array(Set(inWindow + tail)).filter { $0 > 0 }.sorted()
    }

    /// Domain-separation tag mixed in before any tokens.
    private static let domainTag = Data("dbkv-prefix-v1".utf8)

    /// Per-tenant scope tag, mixed in AFTER the domain tag and BEFORE the
    /// tokens. `scope` is an opaque per-consumer string (e.g.
    /// `SHA256(prompt_cache_key)`); folding it into the digest makes a cached
    /// prefix for tenant A undiscoverable by tenant B (closes the TB-007
    /// cross-tenant prefix-sharing channel for the checkpoint tier).
    ///
    /// BACK-COMPAT INVARIANT: an EMPTY scope mixes in NOTHING, so the digest is
    /// byte-identical to the pre-scope implementation. Existing on-disk
    /// checkpoint files (written unscoped) therefore still match an unscoped
    /// lookup. A non-empty scope is length-prefixed (`"dbkv-scope-v1" ‖
    /// u64(len) ‖ scopeBytes`) so it can't collide with token data or with a
    /// different-length scope.
    private static let scopeTag = Data("dbkv-scope-v1".utf8)

    private static func mixScope(_ scope: String, into hasher: inout SHA256) {
        guard !scope.isEmpty else { return }  // empty ⇒ identical to pre-scope digest
        let bytes = Data(scope.utf8)
        hasher.update(data: scopeTag)
        var len = UInt64(bytes.count).littleEndian
        withUnsafeBytes(of: &len) { hasher.update(data: Data($0)) }
        hasher.update(data: bytes)
    }

    /// Compute the digest of exactly the first `length` tokens, scoped to
    /// `scope` (empty ⇒ unscoped, byte-identical to the legacy digest).
    /// `length` must be in `0...tokens.count`.
    public static func digest(tokens: [Int], length: Int, scope: String = "") -> Data {
        precondition(length >= 0 && length <= tokens.count, "length out of range")
        var hasher = SHA256()
        hasher.update(data: domainTag)
        mixScope(scope, into: &hasher)
        for i in 0..<length {
            appendToken(tokens[i], to: &hasher)
        }
        return Data(hasher.finalize())
    }

    /// Compute `(length, digest)` for every checkpoint boundary `≤
    /// tokens.count`, ascending by length. Single pass over the tokens.
    /// `scope` (empty ⇒ unscoped) is folded in identically to `digest(...)`.
    public static func checkpoints(
        tokens: [Int],
        boundaries: [Int] = defaultCheckpoints,
        scope: String = ""
    ) -> [(length: Int, digest: Data)] {
        // Dedup so a caller passing a duplicated boundary doesn't get a
        // double-emitted checkpoint.
        let sorted = Array(Set(boundaries.filter { $0 > 0 })).sorted()
        guard !sorted.isEmpty, !tokens.isEmpty else { return [] }

        var hasher = SHA256()
        hasher.update(data: domainTag)
        mixScope(scope, into: &hasher)

        var result: [(length: Int, digest: Data)] = []
        var bi = 0
        for i in 0..<tokens.count {
            appendToken(tokens[i], to: &hasher)
            let count = i + 1
            // A boundary may equal `count`; emit a finalized snapshot.
            while bi < sorted.count && sorted[bi] <= count {
                if sorted[bi] == count {
                    var snap = hasher
                    result.append((count, Data(snap.finalize())))
                }
                bi += 1
            }
            if bi >= sorted.count { break }
        }
        return result
    }

    /// The checkpoint boundaries that apply to a prompt of `count`
    /// tokens (those `≤ count`), ascending.
    public static func applicableCheckpoints(
        count: Int,
        boundaries: [Int] = defaultCheckpoints
    ) -> [Int] {
        boundaries.filter { $0 > 0 && $0 <= count }.sorted()
    }

    // MARK: - Helpers

    private static func appendToken(_ token: Int, to hasher: inout SHA256) {
        var le = Int64(token).littleEndian
        withUnsafeBytes(of: &le) { hasher.update(data: Data($0)) }
    }
}

// MARK: - Hex helpers

extension Data {
    /// Lowercase hex string. Used to key the index by digest.
    public var dbkvHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
