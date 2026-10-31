import DarkbloomClusterProtocol
import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

// A request's prefix partition on the pair's ranks: the request fingerprint
// both ranks compare binds it, every prefix path takes its scope from one
// helper, and the resident caches find an entry only under the partition it
// was kept with. Pure contracts: no collective, model or GPU evaluation (the
// kept states hold no arrays).

private let tenantA = ClusterWorkerPrefixCache.tenant(ClusterWorkerPrefixCache.tenantDigest(salt: "tenant-a"))
private let tenantB = ClusterWorkerPrefixCache.tenant(ClusterWorkerPrefixCache.tenantDigest(salt: "tenant-b"))

private func profile() throws -> QwenLayerStageGenerationProfile {
    try QwenLayerStageGenerationProfile(identifier: "prefix-tenant-fixture", vocabularySize: 512,
        hiddenSize: 32, activationDType: "bfloat16", maximumPromptTokens: 256,
        maximumChunkTokens: 16, maximumOutputTokens: 8, maximumContextTokens: 512)
}

private func request(_ cache: ClusterWorkerPrefixCache?, id: UUID = UUID(uuidString: "3b1f0c2a-7d4e-4f9a-8c61-5e2d9a0b7c13")!,
                     prompt: [Int] = Array(0..<100)) throws -> QwenLayerStageGenerationRequest {
    try QwenLayerStageGenerationRequest(profile: profile(), requestID: id, promptTokenIDs: prompt,
        chunkSize: 16, outputCount: 3, stopTokenIDs: [], prefixCache: cache)
}

private func keptState(_ frontier: Int) -> QwenStagePrefixState {
    QwenStagePrefixState(committedTokens: frontier, attention: [:], recurrent: [:])
}

@Suite("Prompt prefix tenant partitions (contracts, no execution)")
struct PrefixTenantScopeTests {
    /// Ranks told different partitions disagree on the request before any
    /// prefix exchange; a request without one keeps its exact fingerprint.
    @Test func theRequestFingerprintBindsThePartition() throws {
        let legacy = try QwenLayerStageGenerationRequest(profile: profile(),
            requestID: UUID(uuidString: "3b1f0c2a-7d4e-4f9a-8c61-5e2d9a0b7c13")!, promptTokenIDs: Array(0..<100),
            chunkSize: 16, outputCount: 3, stopTokenIDs: [])
        let plain = try request(nil)
        #expect(plain.fingerprint == legacy.fingerprint && plain == legacy)
        let fingerprints = try [nil, ClusterWorkerPrefixCache.disabled, tenantA, tenantB].map { try request($0).fingerprint }
        #expect(Set(fingerprints).count == 4)
        // A planned copy keeps the partition and the fingerprint.
        let unplanned = try request(tenantA)
        let planned = try unplanned.planned(reusedPrefix: 32, splitFinalToken: true)
        #expect(planned.prefixCache == tenantA && planned.fingerprint == unplanned.fingerprint)
    }

    /// The resident stage cache: an entry is found only under the partition
    /// it was kept with; the same tenant still hits; the scope helper gives a
    /// request whose cache is off no scope at all.
    @Test func residentStageEntriesAreFoundOnlyUnderTheirTenant() throws {
        let load = "plan|artifact|storage|configuration|policy|profile|chunk=16"
        let prompt = Array(0..<100)
        let scopeA = try #require(ClusterWorkerPrefixCache.scope(load, tenantA))
        let scopeB = try #require(ClusterWorkerPrefixCache.scope(load, tenantB))
        #expect(ClusterWorkerPrefixCache.scope(load, .disabled) == nil)
        let cache = QwenStagePrefixCache()
        cache.insert(scope: scopeA, tokens: prompt, states: [keptState(32), keptState(64), keptState(99)])
        #expect(cache.frontiers(scope: scopeA, tokens: prompt, maximumFrontier: 99) == [99, 64, 32])
        #expect(cache.deepestFrontier(scope: scopeA, tokens: prompt, maximumFrontier: 99) == 99)
        #expect(cache.state(scope: scopeA, tokens: prompt, frontier: 64)?.committedTokens == 64)
        for other in [scopeB, load] {
            #expect(cache.frontiers(scope: other, tokens: prompt, maximumFrontier: 99).isEmpty)
            #expect(cache.deepestFrontier(scope: other, tokens: prompt, maximumFrontier: 99) == 0)
            #expect(cache.state(scope: other, tokens: prompt, frontier: 64) == nil)
        }
        // A key is the partition's: the same prompt under another tenant keys apart.
        #expect(QwenStagePrefixCache.key(scope: scopeA, tokens: prompt[0..<64])
            != QwenStagePrefixCache.key(scope: scopeB, tokens: prompt[0..<64]))
        // Tenant B keeps its own entries beside tenant A's; neither sees the other's.
        cache.insert(scope: scopeB, tokens: prompt, states: [keptState(48)])
        #expect(cache.frontiers(scope: scopeA, tokens: prompt, maximumFrontier: 99) == [99, 64, 32])
        #expect(cache.frontiers(scope: scopeB, tokens: prompt, maximumFrontier: 99) == [48])
    }

    /// Every stage family's scope (`qwenStagePrefixScope`): the request's
    /// partition of the agreement's fields, nil when its cache is off.
    @Test func theStageScopeIsTheRequestsPartition() throws {
        let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: String(repeating: "a", count: 64),
            artifactAggregateSHA256: String(repeating: "b", count: 64), storageCommitmentSHA256: String(repeating: "c", count: 64),
            planFingerprint: String(repeating: "d", count: 64), producerStageFingerprint: String(repeating: "e", count: 64))
        let policy = String(repeating: "f", count: 64)
        let plain = try #require(qwenStagePrefixScope(source: source, numericalPolicySHA256: policy, request: try request(nil)))
        // The partition-free scope is the earlier one, field for field.
        let profileFingerprint = try profile().fingerprint
        #expect(plain == [source.planFingerprint, source.artifactAggregateSHA256, source.storageCommitmentSHA256,
            source.sourceConfigurationSHA256, policy, profileFingerprint, "chunk=16"].joined(separator: "|"))
        #expect(qwenStagePrefixScope(source: source, numericalPolicySHA256: policy, request: try request(.disabled)) == nil)
        let a = qwenStagePrefixScope(source: source, numericalPolicySHA256: policy, request: try request(tenantA))
        let b = qwenStagePrefixScope(source: source, numericalPolicySHA256: policy, request: try request(tenantB))
        #expect(a == ClusterWorkerPrefixCache.scope(plain, tenantA) && b == ClusterWorkerPrefixCache.scope(plain, tenantB) && a != b)
    }

    /// GLM tensor parallel: the vote, the restore and the kept boundary all
    /// use one scope, the request's partition of the load agreement, and none
    /// for a request whose cache is off, with media, or on a rank whose cache
    /// is off. Without a partition it is the load agreement itself, as before.
    @Test func glmTensorParallelRequestsKeepPrefixesOnlyUnderTheirPartition() throws {
        let load = String(repeating: "9", count: 64)
        typealias Runtime = GLM5NextTensorParallelResidentRuntime
        #expect(Runtime.prefixScope(load: load, request: try request(nil), cacheOn: true, media: false) == load)
        #expect(Runtime.prefixScope(load: load, request: try request(.disabled), cacheOn: true, media: false) == nil)
        #expect(Runtime.prefixScope(load: load, request: try request(tenantA), cacheOn: true, media: false)
            == ClusterWorkerPrefixCache.scope(load, tenantA))
        #expect(Runtime.prefixScope(load: load, request: try request(tenantA), cacheOn: true, media: true) == nil)
        #expect(Runtime.prefixScope(load: load, request: try request(tenantA), cacheOn: false, media: false) == nil)
        // The entries' keys (`GLM5NextTensorParallelPrefixCache`) differ by partition at every boundary.
        let prompt = Array(0..<100), lengths = QwenTensorParallelPrefixCache.candidates(promptCount: 100, chunk: 16)
        let a = QwenTensorParallelPrefixCache.keys(scope: try #require(ClusterWorkerPrefixCache.scope(load, tenantA)),
            prompt: prompt, lengths: lengths)
        let b = QwenTensorParallelPrefixCache.keys(scope: try #require(ClusterWorkerPrefixCache.scope(load, tenantB)),
            prompt: prompt, lengths: lengths)
        let plain = QwenTensorParallelPrefixCache.keys(scope: load, prompt: prompt, lengths: lengths)
        #expect(Set(a).isDisjoint(with: b) && Set(a).isDisjoint(with: plain) && Set(b).isDisjoint(with: plain))
    }

    /// Qwen tensor parallel: both tiers' scopes come from one suffix, the
    /// request's grid, backend, media and partition; a request whose cache is
    /// off has none, and its resident snapshots under another tenant are not
    /// offered.
    @Test func qwenTensorParallelSnapshotsAreFoundOnlyUnderTheirTenant() throws {
        typealias Runtime = QwenTensorParallelResidentRuntime
        let plain = Runtime.batchPrefixScope(try request(nil), kind: .paged, mediaIdentity: nil)
        #expect(plain == "chunk=16|kv=paged|text")
        #expect(Runtime.batchPrefixScope(try request(.disabled), kind: .paged, mediaIdentity: nil) == nil)
        let scopeA = try #require(Runtime.batchPrefixScope(try request(tenantA), kind: .paged, mediaIdentity: nil))
        let scopeB = try #require(Runtime.batchPrefixScope(try request(tenantB), kind: .paged, mediaIdentity: "m"))
        #expect(scopeA == ClusterWorkerPrefixCache.scope("chunk=16|kv=paged|text", tenantA))
        #expect(scopeB == ClusterWorkerPrefixCache.scope("chunk=16|kv=paged|media=m", tenantB))
        try Device.withDefaultDevice(.cpu) {
            let cache = QwenTensorParallelBatchPrefixCache(enabled: true, budgetBytes: 1 << 20)
            let prompt = Array(0..<100), candidates = QwenTensorParallelBatchPrefixCache.candidates(promptCount: 100,
                chunkSize: 16, maximumTokens: 4096)
            func keys(_ suffix: String) -> [Int: String] {
                QwenTensorParallelBatchPrefixCache.keys(scope: "load|" + suffix, tokens: prompt, frontiers: candidates)
            }
            let a = keys(scopeA), b = keys(ClusterWorkerPrefixCache.scope("chunk=16|kv=paged|text", tenantB)!)
            let none = keys(try #require(plain))
            cache.insert(key: a[96]!, state: .init(committedTokens: 96, attention: [:], recurrent: [:], allocatedBytes: 16))
            #expect(cache.held(keys: a, candidates: candidates).last == 1)
            #expect(cache.held(keys: b, candidates: candidates).allSatisfy { $0 == 0 })
            #expect(cache.held(keys: none, candidates: candidates).allSatisfy { $0 == 0 })
            #expect(!cache.holds(key: b[96]!, frontier: 96) && cache.holds(key: a[96]!, frontier: 96))
        }
    }
}
