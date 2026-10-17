import CryptoKit
import Foundation

/// Cluster cache ownership contracts (private staging, default-off).
///
/// Builds on the existing SSDCacheEpochStore binding seam without changing its
/// behavior: a cluster cache identity is scoped to the account/authorization
/// boundary AND the exact model, prompt contract, build, layout/shard
/// placement, precision and cache epoch. No cross-host raw-KV reuse exists in
/// this contract; when any compatibility field is absent or fuzzy the correct
/// behavior is a safe miss — these types simply cannot be constructed.
///
/// Go mirror: darkbloom-platform coordinator/protocol/cluster_cache_ownership.go. The canonical
/// encodings and the namespace digest MUST stay byte-identical on both sides
/// (shared vector in coordinator/tests/protocol and ProviderCoreTests).

public enum ClusterCacheOwnershipError: String, Error, Sendable, Equatable {
    case invalidIdentity = "Cluster cache identity has missing or fuzzy fields; take a safe miss."
    case staleWriter = "Cluster cache writer is stale for this namespace and root."
    case budgetOverlap = "Rank-local budget counters must not alias the shared physical root."
}

private func clusterCacheIsSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
}

private func clusterCacheBoundedLabel(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximum && value.utf8.allSatisfy({ (33...126).contains($0) })
}

/// Exact cache identity for one cluster namespace. Constructing it proves
/// only that every compatibility field is present and well-formed — reuse
/// itself still requires the existing block/epoch evidence.
public struct ClusterCacheIdentity: Sendable, Equatable {
    /// Authorization boundary (account/lease scope). Never a raw prompt, user
    /// name or free-form label: a coordinator-issued opaque scope digest.
    public let authorizationScopeSHA256: String
    public let modelAggregateSHA256: String
    public let promptContractID: String
    public let buildSHA256: String
    /// Exact layout/shard placement (plan fingerprint), including rank cut.
    public let layoutSHA256: String
    /// Native activation precision (closed vocabulary, mirrors the stage wire).
    public let activationDType: String
    /// The serving cache epoch this namespace publishes under.
    public let cacheEpoch: String

    public init(authorizationScopeSHA256: String, modelAggregateSHA256: String,
                promptContractID: String, buildSHA256: String, layoutSHA256: String,
                activationDType: String, cacheEpoch: String) throws {
        guard clusterCacheIsSHA256(authorizationScopeSHA256),
              clusterCacheIsSHA256(modelAggregateSHA256),
              clusterCacheIsSHA256(buildSHA256),
              clusterCacheIsSHA256(layoutSHA256),
              clusterCacheBoundedLabel(promptContractID, maximum: 128),
              clusterCacheBoundedLabel(cacheEpoch, maximum: 64),
              ["float16", "bfloat16", "float32"].contains(activationDType) else {
            throw ClusterCacheOwnershipError.invalidIdentity
        }
        self.authorizationScopeSHA256 = authorizationScopeSHA256
        self.modelAggregateSHA256 = modelAggregateSHA256
        self.promptContractID = promptContractID
        self.buildSHA256 = buildSHA256
        self.layoutSHA256 = layoutSHA256
        self.activationDType = activationDType
        self.cacheEpoch = cacheEpoch
    }

    /// Fixed-width canonical encoding; no JSON, optional fields or ambiguous
    /// joins. Mirrors ClusterCacheIdentityCanonical (Go) byte for byte.
    public var canonicalBytes: Data {
        var result = Data("darkbloom/cluster-cache-identity/v1\0".utf8)
        for value in [authorizationScopeSHA256, modelAggregateSHA256, buildSHA256, layoutSHA256] {
            result.append(contentsOf: value.utf8)
        }
        for value in [promptContractID, activationDType, cacheEpoch] {
            let bytes = Data(value.utf8)
            var count = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { result.append(contentsOf: $0) }
            result.append(bytes)
        }
        return result
    }

    /// The single digest every writer/fence decision for this cache uses.
    public var namespaceSHA256: String {
        Data(SHA256.hash(data: canonicalBytes)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Authoritative-writer fencing for one cache namespace on one physical
/// storage root. Multiple processes or logical ranks may share a root; only
/// the recorded owner may write. A stale owner (superseded process or epoch)
/// must refuse to write rather than race a replacement.
public struct ClusterCacheWriterLease: Sendable, Equatable {
    /// Canonical physical-root key (the same normalization the epoch store
    /// applies): rank-local counters are keyed per root, so two ranks can
    /// never present their local budgets as one shared budget, and one root
    /// can never be split into two namespaces by path aliasing.
    public static func canonicalRootKey(_ root: URL) -> String {
        root.resolvingSymlinksInPath().standardizedFileURL.path
    }

    public let namespaceSHA256: String
    public let physicalRootKey: String
    public let ownerProcessID: Int32
    public let ownerRank: Int
    public let leaseEpoch: UInt64

    public init(namespaceSHA256: String, physicalRootKey: String,
                ownerProcessID: Int32, ownerRank: Int, leaseEpoch: UInt64) throws {
        guard clusterCacheIsSHA256(namespaceSHA256),
              clusterCacheBoundedLabel(physicalRootKey, maximum: 4096),
              physicalRootKey.hasPrefix("/"),
              ownerProcessID > 0, (0...1).contains(ownerRank), leaseEpoch > 0 else {
            throw ClusterCacheOwnershipError.invalidIdentity
        }
        self.namespaceSHA256 = namespaceSHA256
        self.physicalRootKey = physicalRootKey
        self.ownerProcessID = ownerProcessID
        self.ownerRank = ownerRank
        self.leaseEpoch = leaseEpoch
    }

    /// The ONLY write admission rule. Anything that is not the exact recorded
    /// owner at the current epoch is a stale writer and fails closed.
    public func admitsWriter(processID: Int32, rank: Int, epoch: UInt64) throws {
        guard processID == ownerProcessID, rank == ownerRank, epoch == leaseEpoch else {
            throw ClusterCacheOwnershipError.staleWriter
        }
    }

    /// Supersession requires a strictly newer epoch and a different owner;
    /// reconnects of the previous owner never regain an old namespace.
    public func superseded(by processID: Int32, rank: Int, epoch: UInt64) throws -> ClusterCacheWriterLease {
        guard epoch > leaseEpoch, processID != ownerProcessID || rank != ownerRank else {
            throw ClusterCacheOwnershipError.staleWriter
        }
        return try ClusterCacheWriterLease(namespaceSHA256: namespaceSHA256,
            physicalRootKey: physicalRootKey, ownerProcessID: processID,
            ownerRank: rank, leaseEpoch: epoch)
    }
}
