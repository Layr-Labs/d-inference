import CryptoKit
import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Bounded checkpoint donation hashes")
struct SSDCheckpointDonationHashTests {
    @Test("actual chain work ends at each checkpoint and retains the legacy hash and tag")
    func boundedChainRetainsExactAddresses() throws {
        let fixture = try SSDCheckpointDonationHashFixture()
        defer { fixture.remove() }
        let store = fixture.store
        for count in [16_384, 16_513] {
            let tokens = SSDCheckpointDonationHashFixture.tokens(count)
            let legacy = store.hashes(tokens: tokens, scope: "scope-a")
            for position in [256, 1_024, 4_096, 6_144, 12_288, 16_128] {
                let chain = try #require(store.donationHashes(
                    tokens: tokens, scope: "scope-a", checkpointPosition: position))
                let offset = position / PrefixCachePolicy.blockSize - 1
                #expect(chain.count == position / PrefixCachePolicy.blockSize)
                #expect(chain[offset] == legacy[offset])
                #expect(store.lookupKeys.checkpointTag(chainHash: chain[offset], cacheSalt: "scope-a")
                    == store.lookupKeys.checkpointTag(chainHash: legacy[offset], cacheSalt: "scope-a"))
            }
        }
        // The helper's 256-token hash domain does not lower serving admission.
        #expect(store.config.minEffectiveTokens == 1_024)
    }

    @Test("ordinary aligned-final refusal and diffusion-text aligned-final allowance are unchanged")
    func originalBackendEndpointRules() throws {
        for layout in [CBv2CompleteCheckpointManifest.pagedLayout,
                       CBv2CompleteCheckpointManifest.diffusionBlockLayout] {
            let fixture = try SSDCheckpointDonationHashFixture(layout: layout)
            defer { fixture.remove() }
            let store = fixture.store
            let aligned = SSDCheckpointDonationHashFixture.tokens(1_024)
            let legacy = store.hashes(tokens: aligned, scope: "scope-a")
            let final = store.donationHashes(tokens: aligned, scope: "scope-a", checkpointPosition: 1_024)
            if layout == CBv2CompleteCheckpointManifest.diffusionBlockLayout {
                #expect(legacy.count == 4)
                let chain = try #require(final)
                #expect(chain.count == 4 && chain[3] == legacy[3])
            } else {
                #expect(legacy.count == 3)
                #expect(final == nil)
            }
            let ragged = aligned + [19]
            let interior = try #require(store.donationHashes(
                tokens: ragged, scope: "scope-a", checkpointPosition: 1_024))
            #expect(interior.count == 4)
            #expect(interior[3] == store.hashes(tokens: ragged, scope: "scope-a")[3])
            let earlier = try #require(store.donationHashes(
                tokens: ragged, scope: "scope-a", checkpointPosition: 512))
            #expect(earlier.count == 2)
            #expect(earlier[1] == store.hashes(tokens: ragged, scope: "scope-a")[1])
        }
    }

    @Test("invalid checkpoint geometry is rejected before reading any token or hash index")
    func invalidGeometryCannotEnterHasher() throws {
        let fixture = try SSDCheckpointDonationHashFixture()
        defer { fixture.remove() }
        for position in [Int.min, -256, -1, 0, 1, 255, 257, 1_280, Int.max] {
            #expect(fixture.store.donationHashes(
                tokens: SSDCheckpointDonationHashFixture.tokens(1_025), scope: "scope-a",
                checkpointPosition: position) == nil)
        }
        // This would trigger the real hasher's token precondition if the
        // invalid geometry were not checked first.
        #expect(fixture.store.donationHashes(tokens: [-1], scope: "scope-a", checkpointPosition: 0) == nil)
        #expect(fixture.store.donationHashes(tokens: [], scope: "scope-a", checkpointPosition: 256) == nil)
    }

    @Test("unique extensions retain the tag while a prefix mutation changes it")
    func prefixAndSuffixMutations() throws {
        let fixture = try SSDCheckpointDonationHashFixture()
        defer { fixture.remove() }
        let store = fixture.store
        let original = SSDCheckpointDonationHashFixture.tokens(1_025)
        var suffix = original; suffix[512] += 1; suffix[1_024] += 1
        var prefix = original; prefix[511] += 1
        let originalHash = try #require(store.donationHashes(
            tokens: original, scope: "scope-a", checkpointPosition: 512))[1]
        let suffixHash = try #require(store.donationHashes(
            tokens: suffix, scope: "scope-a", checkpointPosition: 512))[1]
        let prefixHash = try #require(store.donationHashes(
            tokens: prefix, scope: "scope-a", checkpointPosition: 512))[1]
        #expect(originalHash == suffixHash)
        #expect(originalHash != prefixHash)
        #expect(store.lookupKeys.checkpointTag(chainHash: originalHash, cacheSalt: "scope-a")
            == store.lookupKeys.checkpointTag(chainHash: suffixHash, cacheSalt: "scope-a"))
        #expect(store.lookupKeys.checkpointTag(chainHash: originalHash, cacheSalt: "scope-a")
            != store.lookupKeys.checkpointTag(chainHash: prefixHash, cacheSalt: "scope-a"))
    }

    @Test("scope, prompt contract, KEK and the full store namespace retain their isolation")
    func scopedHashesAndArtifactNamespaces() throws {
        let fixture = try SSDCheckpointDonationHashFixture()
        defer { fixture.remove() }
        let store = fixture.store
        let tokens = SSDCheckpointDonationHashFixture.tokens(1_025)
        let first = try #require(store.donationHashes(tokens: tokens, scope: "scope-a", checkpointPosition: 512))[1]
        let otherScope = try #require(store.donationHashes(tokens: tokens, scope: "scope-b", checkpointPosition: 512))[1]
        #expect(first != otherScope)
        let original = store.identity
        let contract = CBv2CompleteCheckpointIdentity(
            modelAggregateHash: original.modelAggregateHash, promptContractID: String(repeating: "b", count: 64),
            buildID: original.buildID, numericsFingerprint: original.numericsFingerprint)
        let contractFixture = try SSDCheckpointDonationHashFixture(identity: contract)
        defer { contractFixture.remove() }
        let otherContract = try #require(contractFixture.store.donationHashes(
            tokens: tokens, scope: "scope-a", checkpointPosition: 512))[1]
        #expect(first != otherContract)
        let tag = store.lookupKeys.checkpointTag(chainHash: first, cacheSalt: "scope-a")
        let otherKey = SSDLookupKeys(kek: SymmetricKey(data: Data(repeating: 8, count: 32)))
        #expect(tag != otherKey.checkpointTag(chainHash: first, cacheSalt: "scope-a"))
        #expect(tag != store.lookupKeys.checkpointTag(chainHash: first, cacheSalt: "scope-b"))
        #expect(tag != store.lookupKeys.checkpointTag(chainHash: otherContract, cacheSalt: "scope-a"))
        let namespace = SSDHybridCheckpointStoreFactory.namespace(
            modelId: "model-a", identity: store.identity, backendLayout: store.config.backendLayout)
        #expect(namespace != SSDHybridCheckpointStoreFactory.namespace(
            modelId: "model-b", identity: store.identity, backendLayout: store.config.backendLayout))
        let variants = [contract,
            CBv2CompleteCheckpointIdentity(modelAggregateHash: original.modelAggregateHash + "-other",
                promptContractID: original.promptContractID, buildID: original.buildID,
                numericsFingerprint: original.numericsFingerprint),
            CBv2CompleteCheckpointIdentity(modelAggregateHash: original.modelAggregateHash,
                promptContractID: original.promptContractID, buildID: original.buildID + "-other",
                numericsFingerprint: original.numericsFingerprint),
            CBv2CompleteCheckpointIdentity(modelAggregateHash: original.modelAggregateHash,
                promptContractID: original.promptContractID, buildID: original.buildID,
                numericsFingerprint: original.numericsFingerprint + "-other")]
        for identity in variants {
            #expect(namespace != SSDHybridCheckpointStoreFactory.namespace(
                modelId: "model-a", identity: identity, backendLayout: store.config.backendLayout))
        }
        #expect(namespace != SSDHybridCheckpointStoreFactory.namespace(
            modelId: "model-a", identity: store.identity,
            backendLayout: CBv2CompleteCheckpointManifest.historicalAttentionLayout))
    }

    @Test("an explicit bound cannot enlarge lookup and native media keeps its separate nonaligned contract")
    func optionalBoundAndNativeMediaRemainIndependent() throws {
        for layout in [CBv2CompleteCheckpointManifest.pagedLayout,
                       CBv2CompleteCheckpointManifest.diffusionBlockLayout] {
            let fixture = try SSDCheckpointDonationHashFixture(layout: layout)
            defer { fixture.remove() }
            let tokens = SSDCheckpointDonationHashFixture.tokens(1_024)
            let legacy = fixture.store.hashes(tokens: tokens, scope: "scope-a")
            #expect(fixture.store.hashes(tokens: tokens, scope: "scope-a", maximumBlocks: 10) == legacy)
            #expect(fixture.store.hashes(tokens: tokens, scope: "scope-a", maximumBlocks: 0).isEmpty)
            #expect(fixture.store.hashes(tokens: tokens, scope: "scope-a", maximumBlocks: -1).isEmpty)
        }
        let fixture = try SSDCheckpointDonationHashFixture(layout: CBv2CompleteCheckpointManifest.diffusionBlockLayout)
        defer { fixture.remove() }
        let tokens = SSDCheckpointDonationHashFixture.tokens(1_600)
        #expect(fixture.store.donationHashes(tokens: tokens, scope: "scope-a", checkpointPosition: 1_503) == nil)
        let media = try NativeDiffusionCheckpointKeys.hashes(tokens: tokens, positions: [1_503],
            promptContractID: fixture.store.identity.promptContractID, scope: "scope-a")
        #expect(media[1_503] != nil)
    }
}
