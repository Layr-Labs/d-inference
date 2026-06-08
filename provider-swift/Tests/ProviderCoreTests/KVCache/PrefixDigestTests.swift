import Foundation
import Testing
@testable import ProviderCore

// P2 unit tests for the exact-checkpoint digest keys.

@Test
func digestIsDeterministicAndPrefixSensitive() {
    let a = PrefixDigest.digest(tokens: [1, 2, 3, 4], length: 4)
    let b = PrefixDigest.digest(tokens: [1, 2, 3, 4], length: 4)
    #expect(a == b, "digest must be deterministic")

    let c = PrefixDigest.digest(tokens: [1, 2, 3, 5], length: 4)
    #expect(a != c, "different tokens → different digest")

    let shorter = PrefixDigest.digest(tokens: [1, 2, 3, 4], length: 3)
    #expect(a != shorter, "different length → different digest (SHA padding encodes length)")
}

@Test
func checkpointDigestEqualsIndependentPrefixHash() {
    // The single-pass checkpoint snapshot must equal an independent hash
    // of the first N tokens — this is what lets a longer cached prefix
    // be found from a shorter shared one.
    let tokens = (0..<5000).map { $0 % 257 }  // 5000 tokens
    let cps = PrefixDigest.checkpoints(tokens: tokens)  // 256,512,1024,2048,4096

    #expect(cps.map { $0.length } == [256, 512, 1024, 2048, 4096])
    for cp in cps {
        let independent = PrefixDigest.digest(tokens: tokens, length: cp.length)
        #expect(cp.digest == independent,
                "checkpoint \(cp.length) digest != independent hash of first \(cp.length) tokens")
    }
}

@Test
func checkpointsRespectTokenCount() {
    let tokens = (0..<700).map { $0 }  // only 256 and 512 apply
    let cps = PrefixDigest.checkpoints(tokens: tokens)
    #expect(cps.map { $0.length } == [256, 512])

    #expect(PrefixDigest.applicableCheckpoints(count: 700) == [256, 512])
    #expect(PrefixDigest.applicableCheckpoints(count: 100) == [])
    #expect(PrefixDigest.applicableCheckpoints(count: 8192).last == 8192)
}

@Test
func sharedPrefixProducesSharedCheckpointDigests() {
    // Two prompts sharing the first 600 tokens but diverging after must
    // agree on the 256 and 512 checkpoint digests (the basis for
    // exact-checkpoint reuse of a shared system prompt).
    let shared = (0..<600).map { $0 }
    let promptA = shared + [9001, 9002, 9003]
    let promptB = shared + [7001, 7002]

    let a = PrefixDigest.checkpoints(tokens: promptA)
    let b = PrefixDigest.checkpoints(tokens: promptB)

    let aByLen = Dictionary(uniqueKeysWithValues: a.map { ($0.length, $0.digest) })
    let bByLen = Dictionary(uniqueKeysWithValues: b.map { ($0.length, $0.digest) })

    #expect(aByLen[256] == bByLen[256])
    #expect(aByLen[512] == bByLen[512])
}

@Test
func customBoundariesWork() {
    let tokens = (0..<100).map { $0 }
    let cps = PrefixDigest.checkpoints(tokens: tokens, boundaries: [10, 50, 100])
    #expect(cps.map { $0.length } == [10, 50, 100])
    #expect(cps[1].digest == PrefixDigest.digest(tokens: tokens, length: 50))
}

@Test
func emptyTokensYieldNoCheckpoints() {
    #expect(PrefixDigest.checkpoints(tokens: []).isEmpty)
}

// MARK: - Per-tenant scope (prompt_cache_key) — TB-007 checkpoint-tier isolation

@Test
func emptyScopeIsByteIdenticalToLegacyDigest() {
    // BACK-COMPAT: an empty scope must mix in NOTHING, so existing on-disk
    // (unscoped) checkpoint files still match an unscoped lookup.
    let tokens = (0..<300).map { $0 * 7 % 1000 }
    for len in [1, 64, 128, 256, 300] {
        let legacy = PrefixDigest.digest(tokens: tokens, length: len)
        let emptyScoped = PrefixDigest.digest(tokens: tokens, length: len, scope: "")
        #expect(legacy == emptyScoped, "empty scope must equal the legacy digest at length \(len)")
    }
    // checkpoints() too.
    let legacyCps = PrefixDigest.checkpoints(tokens: tokens, boundaries: [256])
    let emptyCps = PrefixDigest.checkpoints(tokens: tokens, boundaries: [256], scope: "")
    #expect(legacyCps.map { $0.digest } == emptyCps.map { $0.digest })
}

@Test
func differentScopesProduceDifferentDigests() {
    // ISOLATION: same tokens, different scope ⇒ different digest, so tenant B
    // can never find tenant A's cached prefix (the cache is keyed by digest).
    let tokens = (0..<512).map { $0 }
    let unscoped = PrefixDigest.digest(tokens: tokens, length: 512)
    let scopeA = PrefixDigest.digest(tokens: tokens, length: 512, scope: "tenant-A")
    let scopeB = PrefixDigest.digest(tokens: tokens, length: 512, scope: "tenant-B")
    #expect(scopeA != unscoped, "a non-empty scope must change the digest")
    #expect(scopeB != unscoped)
    #expect(scopeA != scopeB, "distinct scopes must yield distinct digests")
    // Same scope is still deterministic.
    #expect(scopeA == PrefixDigest.digest(tokens: tokens, length: 512, scope: "tenant-A"))
    // And the same holds through checkpoints().
    let a = PrefixDigest.checkpoints(tokens: tokens, boundaries: [256, 512], scope: "tenant-A")
    let b = PrefixDigest.checkpoints(tokens: tokens, boundaries: [256, 512], scope: "tenant-B")
    #expect(a.map { $0.digest } != b.map { $0.digest })
    #expect(a.map { $0.length } == [256, 512], "scope must not change the boundary lengths")
}

@Test
func scopeLengthPrefixingAvoidsBoundaryCollision() {
    // The scope is length-prefixed, so two different scopes whose byte-concat
    // would otherwise alias cannot collide.
    let tokens = [1, 2, 3, 4]
    let d1 = PrefixDigest.digest(tokens: tokens, length: 4, scope: "ab")
    let d2 = PrefixDigest.digest(tokens: tokens, length: 4, scope: "abc")
    #expect(d1 != d2)
}

@Test
func cacheScopePolicy() {
    // prompt_cache_key wins; else user; else "".
    let withKey = ChatCompletionRequest(model: "m", messages: [], user: "u1", prompt_cache_key: "k1")
    #expect(withKey.cacheScope == ChatCompletionRequest.scopeHash("k1"))
    let withUserOnly = ChatCompletionRequest(model: "m", messages: [], user: "u1")
    #expect(withUserOnly.cacheScope == ChatCompletionRequest.scopeHash("u1"))
    let neither = ChatCompletionRequest(model: "m", messages: [])
    #expect(neither.cacheScope == "")
    // Empty strings are treated as absent.
    let emptyKey = ChatCompletionRequest(model: "m", messages: [], user: "", prompt_cache_key: "")
    #expect(emptyKey.cacheScope == "")
    // The hash is the fixed-width hex SHA-256 (opaque, not the raw key).
    #expect(withKey.cacheScope.count == 64)
    #expect(withKey.cacheScope != "k1")
}
