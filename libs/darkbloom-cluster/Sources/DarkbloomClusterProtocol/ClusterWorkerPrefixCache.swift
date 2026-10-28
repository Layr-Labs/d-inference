import CryptoKit
import Foundation

/// How both ranks' prompt-prefix caches, resident and SSD, treat one request:
/// the product's `CBv2Request.prefixCacheEnabled` and `cacheSalt` (the
/// request's authenticated tenant scope; a salt replaces the cache's own, so
/// tenants never share KV). The salt itself never reaches a rank, a marker or
/// a log: a tenant crosses as a fixed-length digest of it (`tenantDigest`).
///
/// A reservation without one (nil) is a request with its cache on and no
/// tenant salt, a local request's, as every request was before reservations
/// carried it; its bytes are then exactly those of a worker without the field.
/// Both ranks bind it into the request fingerprint they compare before any
/// prefix exchange, so ranks told different partitions fail the request.
public enum ClusterWorkerPrefixCache: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// `prefixCacheEnabled` false: neither rank offers a held boundary,
    /// restores or stores this request's prompt prefixes, in memory or on its
    /// SSD tier. Nothing else about the request changes.
    case disabled
    /// A tenant's request: both ranks look up and keep its prompt prefixes
    /// only under this digest (64 lowercase hexadecimal digits,
    /// `tenantDigest(salt:)`), which no other tenant's request, and no request
    /// without a tenant, carries.
    case tenant(String)

    /// The domain of a tenant digest; a new encoding of the salt takes a new one.
    public static let tenantDomain = "darkbloom-cluster-prefix-tenant-v1|"

    /// SHA-256 of the domain and the salt, in lowercase hexadecimal.
    public static func tenantDigest(salt: String) -> String {
        SHA256.hash(data: Data((tenantDomain + salt).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A product request's cache fields as a reservation carries them: nil
    /// for a request whose cache is on without a salt, `disabled` for one
    /// whose cache is off, else its salt's tenant. A salt partitions whatever
    /// its text, as `CBv2Request.cacheSalt` does on one Mac.
    public static func partition(prefixCacheEnabled: Bool, cacheSalt: String?) -> ClusterWorkerPrefixCache? {
        guard prefixCacheEnabled else { return .disabled }
        return cacheSalt.map { .tenant(tenantDigest(salt: $0)) }
    }

    /// The scope a rank keys one request's prompt prefixes by, resident and on
    /// its SSD tier, and the one place every prefix path takes it from:
    /// `load`, what both ranks already agreed for the request (the load, its
    /// grid and media), for a request without a tenant; `load` and the
    /// tenant's digest for a tenant's request; nil for a request whose cache
    /// is off, which then neither offers, restores nor stores a prefix.
    public static func scope(_ load: String, _ cache: ClusterWorkerPrefixCache?) -> String? {
        switch cache {
        case nil: return load
        case .disabled?: return nil
        case .tenant(let digest)?: return load + "|tenant=" + digest
        }
    }

    /// What a request fingerprint binds (`QwenLayerStageGenerationRequest`).
    public var fingerprintField: String {
        switch self {
        case .disabled: return "prefix-cache=disabled"
        case .tenant(let digest): return "prefix-cache=tenant:" + digest
        }
    }

    /// The digest, never the salt; descriptions redact even that, so a logged
    /// reservation cannot link one tenant's requests.
    public var description: String {
        switch self {
        case .disabled: return "ClusterWorkerPrefixCache.disabled"
        case .tenant: return "ClusterWorkerPrefixCache.tenant(<redacted>)"
        }
    }
    public var debugDescription: String { description }

    func validate() throws {
        if case .tenant(let digest) = self {
            try workerRequire(ClusterWorkerValidation.hash(digest), "Invalid prefix-cache tenant digest")
        }
    }

    /// `{"enabled": false}` or `{"enabled": true, "tenantSHA256": digest}`.
    /// The default (on, no tenant) has no wire form: it is the absent field.
    var wireObject: [String: Any] {
        switch self {
        case .disabled: return ["enabled": false]
        case .tenant(let digest): return ["enabled": true, "tenantSHA256": digest]
        }
    }

    static func decode(wire object: [String: Any]) throws -> Self {
        var r = WorkerObject(object)
        let enabled = try r.bool("enabled")
        let value: Self = enabled ? .tenant(try r.string("tenantSHA256")) : .disabled
        try r.finish()
        try value.validate()
        return value
    }
}
