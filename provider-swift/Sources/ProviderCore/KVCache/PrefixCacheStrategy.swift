/// PrefixCacheStrategy — decides which prefix-cache strategy (if any) a model
/// can use, from the cache types its `newCache()` produces.
///
/// There are two correct strategies and they are mutually exclusive per
/// model (see docs/ssd-kv-cache-hybrid-models.md):
///
///   .engine     — ALL layers are `KVCacheSimple` (pure-attention models).
///                 Served by the engine's in-GPU block `PrefixCache`
///                 (256-token, content-addressed). Finest-grained reuse.
///
///   .checkpoint — layers are a mix of `KVCacheSimple` + `RotatingKVCache`
///                 (sliding-window models: Gemma-4, GPT-OSS). A rotating
///                 window CANNOT be block-decomposed by token position
///                 (it discards old KV and rotates physically), so these
///                 models use whole-cache exact-checkpoint snapshots via
///                 `PrefixCacheManager` instead.
///
///   .none       — any layer is recurrent (`MambaCache`/`ArraysCache`) or
///                 otherwise unsupported (Qwen3.5/Next). Not cacheable;
///                 behavior is identical to the cache being disabled.
///
/// This is a PURE classifier with no side effects. It is the single point
/// that guarantees the two tiers never both run for one model, and that
/// uncacheable models fall through to today's exact behavior.
///
/// The block tier's own gate (`Scheduler.swift`, `allSatisfy { $0 is
/// KVCacheSimple }`) is preserved unchanged; `.engine` is exactly the set
/// that gate already accepts, so wiring this classifier cannot change which
/// models the engine tier serves.

import Foundation
import MLXLMCommon

public enum PrefixCacheStrategy: String, Sendable, Equatable {
    case engine
    case checkpoint
    case none

    /// Classify the per-layer caches a model produces (`model.newCache()`).
    /// An empty list is `.none` (nothing to cache).
    public static func classify(_ caches: [any KVCache]) -> PrefixCacheStrategy {
        guard !caches.isEmpty else { return .none }

        var sawRotating = false
        for cache in caches {
            // Order matters: subclasses before their base, mirroring
            // KVCacheSerializer.className (the serializer that must later
            // round-trip these exact types).
            if cache is ArraysCache {            // MambaCache + recurrent
                return .none
            }
            if cache is ChunkedKVCache {         // unsupported KVCacheSimple subclass
                return .none
            }
            if cache is RotatingKVCache {
                sawRotating = true
                continue
            }
            if cache is QuantizedKVCache {
                return .none
            }
            if cache is KVCacheSimple {
                continue
            }
            return .none                         // CacheList / unknown
        }

        return sawRotating ? .checkpoint : .engine
    }

    /// Smallest sliding window across a model's `RotatingKVCache` layers,
    /// or nil if there are none. This is the authoritative window size —
    /// read from the live cache instances the model built, NOT guessed from
    /// config.json (which `ModelArchitecture` doesn't even expose as an
    /// integer). It caps the checkpoint boundaries: a snapshot at length L
    /// is only restorable when every sliding layer still holds all L tokens
    /// (L ≤ window). See `PrefixDigest.checkpoints(forSlidingWindow:)`.
    public static func minSlidingWindow(_ caches: [any KVCache]) -> Int? {
        // RotatingKVCache.maxSize is Int?; flatMap to drop both the
        // non-rotating layers and any nil window.
        caches.compactMap { ($0 as? RotatingKVCache)?.maxSize }.min()
    }
}
