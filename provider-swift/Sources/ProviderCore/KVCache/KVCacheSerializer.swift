/// KVCacheSerializer — converts an extracted `[any KVCache]` (one
/// single-stream cache per layer, from `BatchedCache.extractBatched`)
/// into raw byte chunks + a layout descriptor, and back. This is the
/// glue the SSD tier needs: the chunks feed straight into
/// `EncryptedKVStore` (so plaintext KV never touches disk — we do NOT
/// route through upstream `savePromptCache`, which writes a plaintext
/// `.safetensors`), and the layout JSON rides in the encrypted file's
/// metadata.
///
/// Why our own (not `savePromptCache`): (1) encryption-at-rest requires
/// the plaintext bytes go directly into AES-GCM, never to a temp file;
/// (2) upstream's reconstruction helper is `private`. We reconstruct
/// via each cache type's PUBLIC `state` / `metaState` setters, which is
/// sufficient for every type we support.
///
/// SSD-serializable cache types: `KVCacheSimple` and `RotatingKVCache`
/// — i.e. the attention + sliding-window caches that Gemma-4 26B-A4B
/// and GPT-OSS-20B use, plus all pure-attention models. Both
/// reconstruct via their PUBLIC `state` + `metaState` setters.
///
/// NOT SSD-serializable here: `MambaCache` / `ArraysCache` (recurrent
/// state). Their `metaState` setter deliberately traps
/// (`assertionFailure`) and the real reconstruction path,
/// `ArraysCache.restoreFromMetaState`, is `internal` to MLXLMCommon —
/// unreachable from ProviderCore. Rebuilding recurrent state through
/// the partial public API can't be verified correct without the model,
/// and a wrong recurrent state silently produces garbage tokens, so we
/// refuse rather than guess. Consequence: hybrid models (Qwen3.5/Next)
/// get the RAM tier only (which uses `copy()`, no serialization needed),
/// not SSD persistence — until upstream exposes a public reconstruction.
/// Also unsupported: `ChunkedKVCache`, `QuantizedKVCache`, `CacheList`,
/// custom pooling. `serialize` throws on any unsupported layer; the
/// manager's load-time capability gate (P3) keeps them out first.
///
/// Byte round-trip uses `MLXArray.asData(access: .copy)` (contiguous
/// raw bytes + shape + dtype) and `MLXArray(data:shape:dtype:)` — dtype-
/// agnostic, so bf16 round-trips exactly.

import Foundation
import MLX
import MLXLMCommon

// MARK: - Layout (rides in the encrypted file metadata as JSON)

public struct KVCacheArrayDescriptor: Codable, Sendable, Equatable {
    public let shape: [Int]
    public let dtype: String  // String(describing: DType), e.g. "bfloat16"
}

public struct KVCacheLayerDescriptor: Codable, Sendable, Equatable {
    public let className: String       // canonical class name (see KVCacheSerializer.className)
    public let metaState: [String]     // the cache's metaState, verbatim
    public let arrays: [KVCacheArrayDescriptor]  // one per state array, in order
}

public struct KVCacheLayout: Codable, Sendable, Equatable {
    public let version: Int
    public let layers: [KVCacheLayerDescriptor]
}

// MARK: - Errors

public enum KVCacheSerializerError: Error, CustomStringConvertible, Sendable {
    case unsupportedCacheType(String)
    case chunkCountMismatch(expected: Int, got: Int)
    case unknownDType(String)
    case reconstructionFailed(String)

    public var description: String {
        switch self {
        case .unsupportedCacheType(let t): return "unsupported cache type for prefix cache: \(t)"
        case .chunkCountMismatch(let e, let g): return "chunk count mismatch: layout needs \(e), got \(g)"
        case .unknownDType(let d): return "unknown dtype string: \(d)"
        case .reconstructionFailed(let m): return "cache reconstruction failed: \(m)"
        }
    }
}

// MARK: - Serializer

public enum KVCacheSerializer {

    public static let layoutVersion = 1

    /// DType ↔ string. Built from `DType.allCases` so it stays complete
    /// if MLX adds dtypes.
    private static let dtypeByName: [String: DType] = {
        Dictionary(uniqueKeysWithValues: DType.allCases.map { (String(describing: $0), $0) })
    }()

    /// Canonical class name for an SSD-serializable cache, or nil if
    /// unsupported. Order matters: subclasses are checked before their
    /// base so unsupported subclasses (ArraysCache/MambaCache,
    /// ChunkedKVCache) are excluded before the supported base types.
    public static func className(_ cache: any KVCache) -> String? {
        // Recurrent caches — not SSD-serializable (see file header).
        // ArraysCache covers MambaCache (its subclass).
        if cache is ArraysCache { return nil }
        // Unsupported KVCacheSimple subclass — exclude before KVCacheSimple.
        if cache is ChunkedKVCache { return nil }
        if cache is RotatingKVCache { return "RotatingKVCache" }
        if cache is QuantizedKVCache { return nil }
        if cache is KVCacheSimple { return "KVCache" }
        return nil  // CacheList / unknown
    }

    /// True iff every layer's cache type is supported.
    public static func areSupported(_ caches: [any KVCache]) -> Bool {
        caches.allSatisfy { className($0) != nil }
    }

    // MARK: Serialize

    /// Flatten `caches` to raw byte chunks (in layer-then-array order)
    /// plus a layout describing how to rebuild them.
    public static func serialize(_ caches: [any KVCache]) throws -> (chunks: [Data], layout: KVCacheLayout) {
        var chunks: [Data] = []
        var layers: [KVCacheLayerDescriptor] = []

        for cache in caches {
            guard let name = className(cache) else {
                throw KVCacheSerializerError.unsupportedCacheType(String(describing: type(of: cache)))
            }
            let state = cache.state  // [MLXArray]
            var descriptors: [KVCacheArrayDescriptor] = []
            for arr in state {
                let d = arr.asData(access: .copy)  // evals + contiguous copy
                chunks.append(d.data)
                descriptors.append(
                    KVCacheArrayDescriptor(shape: d.shape, dtype: String(describing: d.dType))
                )
            }
            layers.append(
                KVCacheLayerDescriptor(
                    className: name, metaState: cache.metaState, arrays: descriptors
                )
            )
        }

        return (chunks, KVCacheLayout(version: layoutVersion, layers: layers))
    }

    // MARK: Deserialize

    /// Rebuild `[any KVCache]` from chunks + layout. Reconstructs each
    /// cache via its public init + `state`/`metaState` setters.
    public static func deserialize(chunks: [Data], layout: KVCacheLayout) throws -> [any KVCache] {
        let expectedChunks = layout.layers.reduce(0) { $0 + $1.arrays.count }
        guard chunks.count == expectedChunks else {
            throw KVCacheSerializerError.chunkCountMismatch(expected: expectedChunks, got: chunks.count)
        }

        var caches: [any KVCache] = []
        var idx = 0
        for layer in layout.layers {
            var arrays: [MLXArray] = []
            arrays.reserveCapacity(layer.arrays.count)
            for desc in layer.arrays {
                guard let dt = dtypeByName[desc.dtype] else {
                    throw KVCacheSerializerError.unknownDType(desc.dtype)
                }
                arrays.append(MLXArray(chunks[idx], desc.shape, dtype: dt))
                idx += 1
            }
            caches.append(try reconstruct(className: layer.className, arrays: arrays, metaState: layer.metaState))
        }
        return caches
    }

    // MARK: - Reconstruction

    private static func reconstruct(
        className: String, arrays: [MLXArray], metaState: [String]
    ) throws -> any KVCache {
        // Set state only when there is array data (an empty cache's
        // `state` setter would reject a 0-count array on some types).
        // metaState is always set: each type's setter accepts its own
        // shape and carries the offset/idx the state setter doesn't.
        switch className {
        case "KVCache", "KVCacheSimple":
            let c = KVCacheSimple()
            if !arrays.isEmpty { c.state = arrays }
            c.metaState = metaState
            return c
        case "RotatingKVCache":
            // maxSize is a placeholder; the metaState setter overwrites it.
            let c = RotatingKVCache(maxSize: 1, keep: 0)
            if !arrays.isEmpty { c.state = arrays }
            c.metaState = metaState
            return c
        default:
            // MambaCache/ArraysCache and others are rejected at serialize
            // time; reaching here means a layout from an unsupported source.
            throw KVCacheSerializerError.unsupportedCacheType(className)
        }
    }
}
