import Foundation
import MLXLMCommon

/// Where one remote request's prompt prefix may be kept, from the sealed
/// `_darkbloom_cache.cache_policy` key. A `memoryOnly` request never reads,
/// writes, stages, donates or restores anything on the SSD tier, and keeps
/// nothing in a prefix tier that outlives it without a bound: it runs with its
/// prefix cache off (`PrefixCacheSubmissionPolicy`).
public enum RequestCachePolicy: String, Sendable, Equatable, CaseIterable {
    case `default`
    case memoryOnly = "memory_only"

    /// The policy a present `cache_policy` value selects: only the exact
    /// string `"default"` keeps the SSD tier. Any other value, a non-string
    /// value included (nil), selects `memoryOnly`.
    init(presentValue: String?) {
        self = presentValue == Self.default.rawValue ? .default : .memoryOnly
    }

    /// The policy `key` selects in `container`: an absent key is `default`;
    /// a present one selects as `init(presentValue:)`, a non-string as nil.
    init<Key: CodingKey>(decoding container: KeyedDecodingContainer<Key>, forKey key: Key) {
        self = container.contains(key)
            ? RequestCachePolicy(presentValue: try? container.decode(String.self, forKey: key))
            : .default
    }

    /// The stricter of two policies; a second source can only narrow.
    func narrowed(by other: RequestCachePolicy) -> RequestCachePolicy {
        self == .memoryOnly || other == .memoryOnly ? .memoryOnly : .default
    }

    var permitsSSDTier: Bool { self == .default }

    static let localServingEnvironmentKey = "DARKBLOOM_LOCAL_CACHE_POLICY"

    /// The policy of every request on this Mac's local API, from
    /// `DARKBLOOM_LOCAL_CACHE_POLICY`: unset or empty is `default`, and any
    /// value but `default` is `memoryOnly`. Coordinator requests carry their
    /// own sealed policy and never read it.
    static func localServing(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RequestCachePolicy {
        guard let raw = environment[localServingEnvironmentKey]?.trimmingCharacters(in: .whitespaces),
            !raw.isEmpty
        else { return .default }
        return RequestCachePolicy(presentValue: raw)
    }
}

/// The receipt IDs of a `memoryOnly` request that runs with a prefix cache
/// on: `bit` set and the seeded engine-ID tag (`EngineV2Bridge.seededIdTagBit`)
/// clear, a range no ordinary receipt (counting up from 1) and no engine ID
/// reaches. Each SSD-tier entry point refuses such a request from the ID
/// alone, calls the engine makes after the request's terminal included.
/// While a `memoryOnly` request runs with its cache off
/// (`PrefixCacheSubmissionPolicy`), none is minted and the counts stay 0.
enum MemoryOnlyReceipt {
    static let bit: UInt64 = 1 << 62

    static func contains(_ id: CBv2RequestID?) -> Bool {
        guard let id else { return false }
        return id.raw & (bit | EngineV2Bridge.seededIdTagBit) == bit
    }

    /// True, counted as a refusal, for an engine call into an SSD store
    /// (lookup, stage take, donation) made for a memory-only request.
    static func refusesEngineCall(_ id: CBv2RequestID?) -> Bool {
        guard contains(id) else { return false }
        RequestCachePolicyCounters.shared.recordSSDRefusal()
        return true
    }

    /// True, counted as a touch, for a memory-only request at an SSD read,
    /// write or index path that only the bridge starts or that follows a
    /// refused entry point: the second gate, so the count stays 0.
    static func refusesTierAccess(_ id: CBv2RequestID?) -> Bool {
        guard contains(id) else { return false }
        RequestCachePolicyCounters.shared.recordSSDTierTouch()
        return true
    }
}
