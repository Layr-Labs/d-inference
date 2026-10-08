import Foundation
import Testing
@testable import ProviderCore

// Mirrored cluster cache ownership tests (Go side:
// coordinator/tests/protocol/cluster_cache_ownership_test.go). The canonical
// encoding and namespace digest MUST stay byte-identical across languages.

@Suite("Cluster cache ownership (mirrored contract)")
struct ClusterCacheOwnershipTests {
    private func fixtureIdentity() throws -> ClusterCacheIdentity {
        try ClusterCacheIdentity(
            authorizationScopeSHA256: String(repeating: "1", count: 64),
            modelAggregateSHA256: String(repeating: "2", count: 64),
            promptContractID: "prompt-contract-v1",
            buildSHA256: String(repeating: "3", count: 64),
            layoutSHA256: String(repeating: "4", count: 64),
            activationDType: "bfloat16", cacheEpoch: "epoch-7")
    }

    @Test func canonicalVectorMatchesTheGoMirror() throws {
        let identity = try fixtureIdentity()
        let canonical = identity.canonicalBytes
        #expect(canonical.starts(with: Data("darkbloom/cluster-cache-identity/v1\0".utf8)))
        #expect(canonical.count == 36 + 4 * 64 + 4 + 18 + 4 + 8 + 4 + 7)
        // Pinned with coordinator/tests/protocol/cluster_cache_ownership_test.go;
        // update both sides together.
        #expect(identity.namespaceSHA256 == "d9a9f866e1ab9efb081317777815a95401fe310b1f9e87730d86133f0655a569")
    }

    @Test func fuzzyFieldsTakeASafeMiss() throws {
        let valid = (
            scope: String(repeating: "1", count: 64),
            model: String(repeating: "2", count: 64),
            contract: "pc",
            build: String(repeating: "3", count: 64),
            layout: String(repeating: "4", count: 64),
            dtype: "bfloat16",
            epoch: "e")
        #expect(throws: ClusterCacheOwnershipError.self) {
            _ = try ClusterCacheIdentity(authorizationScopeSHA256: "", modelAggregateSHA256: valid.model,
                promptContractID: valid.contract, buildSHA256: valid.build, layoutSHA256: valid.layout,
                activationDType: valid.dtype, cacheEpoch: valid.epoch)
        }
        #expect(throws: ClusterCacheOwnershipError.self) {
            _ = try ClusterCacheIdentity(authorizationScopeSHA256: String(repeating: "1", count: 63),
                modelAggregateSHA256: valid.model, promptContractID: valid.contract,
                buildSHA256: valid.build, layoutSHA256: valid.layout,
                activationDType: valid.dtype, cacheEpoch: valid.epoch)
        }
        #expect(throws: ClusterCacheOwnershipError.self) {
            _ = try ClusterCacheIdentity(authorizationScopeSHA256: valid.scope,
                modelAggregateSHA256: String(repeating: "G", count: 64),
                promptContractID: valid.contract, buildSHA256: valid.build, layoutSHA256: valid.layout,
                activationDType: valid.dtype, cacheEpoch: valid.epoch)
        }
        #expect(throws: ClusterCacheOwnershipError.self) {
            _ = try ClusterCacheIdentity(authorizationScopeSHA256: valid.scope, modelAggregateSHA256: valid.model,
                promptContractID: "has space", buildSHA256: valid.build, layoutSHA256: valid.layout,
                activationDType: valid.dtype, cacheEpoch: valid.epoch)
        }
        #expect(throws: ClusterCacheOwnershipError.self) {
            _ = try ClusterCacheIdentity(authorizationScopeSHA256: valid.scope, modelAggregateSHA256: valid.model,
                promptContractID: valid.contract, buildSHA256: valid.build, layoutSHA256: valid.layout,
                activationDType: "float64", cacheEpoch: valid.epoch)
        }
        #expect(throws: ClusterCacheOwnershipError.self) {
            _ = try ClusterCacheIdentity(authorizationScopeSHA256: valid.scope, modelAggregateSHA256: valid.model,
                promptContractID: valid.contract, buildSHA256: valid.build, layoutSHA256: valid.layout,
                activationDType: valid.dtype, cacheEpoch: "")
        }
    }

    @Test func writerLeaseFencesStaleOwners() throws {
        let identity = try fixtureIdentity()
        let lease = try ClusterCacheWriterLease(namespaceSHA256: identity.namespaceSHA256,
            physicalRootKey: ClusterCacheWriterLease.canonicalRootKey(
                URL(fileURLWithPath: "/Library/Caches/cluster")),
            ownerProcessID: 4242, ownerRank: 0, leaseEpoch: 7)
        try lease.admitsWriter(processID: 4242, rank: 0, epoch: 7)
        for attempt in [(4242 as Int32, 1, 7 as UInt64), (4243, 0, 7), (4242, 0, 8), (4242, 0, 6)] {
            #expect(throws: ClusterCacheOwnershipError.self) {
                try lease.admitsWriter(processID: attempt.0, rank: attempt.1, epoch: attempt.2)
            }
        }
        // Supersession needs a strictly newer epoch and a different owner.
        #expect(throws: ClusterCacheOwnershipError.self) { _ = try lease.superseded(by: 4242, rank: 0, epoch: 8) }
        #expect(throws: ClusterCacheOwnershipError.self) { _ = try lease.superseded(by: 4243, rank: 0, epoch: 7) }
        let next = try lease.superseded(by: 4243, rank: 1, epoch: 8)
        #expect(throws: ClusterCacheOwnershipError.self) { try next.admitsWriter(processID: 4242, rank: 0, epoch: 7) }
        try next.admitsWriter(processID: 4243, rank: 1, epoch: 8)
        // Root keys normalize symlinks/standardization so rank-local counters
        // cannot alias or split a shared physical root.
        #expect(ClusterCacheWriterLease.canonicalRootKey(URL(fileURLWithPath: "/tmp/../tmp/x"))
            == ClusterCacheWriterLease.canonicalRootKey(URL(fileURLWithPath: "/tmp/x")))
    }
}
