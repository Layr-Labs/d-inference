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
///
/// DO NOT "dedup K==V" for Gemma's `attention_k_eq_v` layers to halve the
/// on-disk size. That flag shares the *projection weights* (V reuses K's
/// raw projection, so there is no separate `v_proj`), NOT the cached
/// tensors. Verified in `Gemma4Text.swift`: the cached K = `RoPE(kNorm(kRaw))`
/// (full RMSNorm WITH learned scale + rotary), while V = `vNorm(kRaw)`
/// (`RMSNormNoScale`, NO scale, NO rotary). K and V are therefore
/// numerically DIFFERENT tensors; storing one and aliasing it as the other
/// would silently corrupt V on restore. The only lever for smaller
/// endpoints is lossy fp8/int8 KV (which breaks bit-exact restore) — a
/// separate, opt-in decision, not a free dedup.

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
        // chunkPlaintextSizes equality and GCM AAD already bind the bytes
        // to the metadata; what they do NOT bind is that the metadata
        // matches the model about to consume the KV. Callers serving KV
        // MUST first call `validateLayout(_:kvHeads:headDim:)` so a
        // self-consistent file whose shapes disagree with the live model
        // is rejected (cold miss) rather than seeded.

        var caches: [any KVCache] = []
        var idx = 0
        for layer in layout.layers {
            var arrays: [MLXArray] = []
            arrays.reserveCapacity(layer.arrays.count)
            for desc in layer.arrays {
                guard let dt = dtypeByName[desc.dtype] else {
                    throw KVCacheSerializerError.unknownDType(desc.dtype)
                }
                // Bind the declared shape to the actual chunk byte length
                // BEFORE constructing the MLXArray: its init has a hard
                // precondition (an UNCATCHABLE trap) when
                // shape.product*dtype.size != byteCount, and computing that
                // product itself traps on a negative dim or Int overflow. A
                // foreign/tampered descriptor could carry a shape that
                // disagrees with its chunk; reject it as a cold miss.
                let expected = try expectedByteCount(shape: desc.shape, dtype: dt)
                guard chunks[idx].count == expected else {
                    throw KVCacheSerializerError.reconstructionFailed(
                        "chunk \(idx): \(chunks[idx].count) bytes != shape \(desc.shape) "
                            + "x \(desc.dtype) (\(expected) bytes)")
                }
                arrays.append(MLXArray(chunks[idx], desc.shape, dtype: dt))
                idx += 1
            }
            caches.append(try reconstruct(className: layer.className, arrays: arrays, metaState: layer.metaState))
        }
        return caches
    }

    /// Byte count for a declared shape+dtype, guarding the two ways a
    /// foreign/tampered descriptor would otherwise hard-trap MLXArray's
    /// init: a negative dim, or an Int-overflowing product.
    private static func expectedByteCount(shape: [Int], dtype: DType) throws -> Int {
        var elements = 1
        for d in shape {
            guard d >= 0 else {
                throw KVCacheSerializerError.reconstructionFailed("negative dim in shape \(shape)")
            }
            let (p, overflow) = elements.multipliedReportingOverflow(by: d)
            guard !overflow else {
                throw KVCacheSerializerError.reconstructionFailed("shape \(shape) element count overflows")
            }
            elements = p
        }
        let (bytes, overflow) = elements.multipliedReportingOverflow(by: dtype.size)
        guard !overflow else {
            throw KVCacheSerializerError.reconstructionFailed("shape \(shape) byte count overflows")
        }
        return bytes
    }

    // MARK: - Validation

    /// Verify a layout's KV tensor shapes match the model the caller is
    /// about to serve. The load-path MB-1/shape guards only compare the
    /// metadata *integers* (meta.kvHeads/headDim); the actual tensors that
    /// seed attention come from `layout.layers[].arrays[].shape`, a
    /// separate field never cross-checked. A file that is self-consistent
    /// (and authenticates under its own GCM AAD) but whose layout shape
    /// disagrees with the live model — e.g. weights changed under the same
    /// model id, or a foreign file in the disk-tamper threat model — would
    /// otherwise deserialize and seed wrong-shaped KV, corrupting
    /// generation or trapping inside MLX. KV arrays are
    /// [batch, kvHeads, seq, headDim]; bind dims 1 and 3 to the model.
    public static func validateLayout(_ layout: KVCacheLayout, kvHeads: Int, headDim: Int) throws {
        for (li, layer) in layout.layers.enumerated() {
            for (ai, arr) in layer.arrays.enumerated() {
                guard arr.shape.count == 4 else {
                    throw KVCacheSerializerError.reconstructionFailed(
                        "layer \(li) array \(ai): expected rank-4 KV tensor, got shape \(arr.shape)")
                }
                guard arr.shape[1] == kvHeads, arr.shape[3] == headDim else {
                    throw KVCacheSerializerError.reconstructionFailed(
                        "layer \(li) array \(ai): KV shape \(arr.shape) disagrees with model "
                            + "(kvHeads=\(kvHeads), headDim=\(headDim))")
                }
            }
        }
    }

    /// Per-layer shape validation for HETEROGENEOUS models. `layerShapes[i]`
    /// is the expected `[kvHeads, headDim]` for layer i (from the live
    /// `model.newCache()`). Gemma-4 interleaves sliding `[8,256]` and full
    /// `[2,512]` layers, so a single (kvHeads, headDim) pair cannot describe
    /// it — using the scalar overload there would reject the model's OWN
    /// freshly-written files and silently disable the SSD cache. Requires the
    /// layer COUNT to match too (a layer-count mismatch is a wrong/foreign
    /// file). Each KV array is [batch, kvHeads, seq, headDim] → dims 1 and 3.
    public static func validateLayout(_ layout: KVCacheLayout, layerShapes: [[Int]]) throws {
        guard layout.layers.count == layerShapes.count else {
            throw KVCacheSerializerError.reconstructionFailed(
                "layer count \(layout.layers.count) disagrees with model (\(layerShapes.count))")
        }
        for (li, layer) in layout.layers.enumerated() {
            let expected = layerShapes[li]  // [kvHeads, headDim]
            guard expected.count == 2 else {
                throw KVCacheSerializerError.reconstructionFailed(
                    "layer \(li): malformed reference shape \(expected)")
            }
            for (ai, arr) in layer.arrays.enumerated() {
                guard arr.shape.count == 4 else {
                    throw KVCacheSerializerError.reconstructionFailed(
                        "layer \(li) array \(ai): expected rank-4 KV tensor, got shape \(arr.shape)")
                }
                guard arr.shape[1] == expected[0], arr.shape[3] == expected[1] else {
                    throw KVCacheSerializerError.reconstructionFailed(
                        "layer \(li) array \(ai): KV shape \(arr.shape) disagrees with model layer "
                            + "(kvHeads=\(expected[0]), headDim=\(expected[1]))")
                }
            }
        }
    }

    /// Validate a metaState array against the requirements of its cache
    /// type's setter BEFORE assigning it. The engine's `metaState` setters
    /// `fatalError` on malformed input (wrong count, non-integer fields,
    /// maxSize=="None"), which a load-path do/catch cannot intercept — a
    /// single stale/foreign file would crash the whole provider. Throwing
    /// instead turns it into a recoverable cold miss.
    private static func validateMetaState(className: String, _ m: [String]) throws {
        switch className {
        case "KVCache", "KVCacheSimple":
            guard m.count == 1, m[0].isEmpty else {
                throw KVCacheSerializerError.reconstructionFailed(
                    "KVCacheSimple metaState must be [\"\"], got \(m.count) element(s)")
            }
        case "RotatingKVCache":
            // [keep, maxSize, step, offset, idx] — all integers, maxSize != None.
            guard m.count == 5 else {
                throw KVCacheSerializerError.reconstructionFailed(
                    "RotatingKVCache metaState must have 5 values, got \(m.count)")
            }
            guard Int(m[0]) != nil, Int(m[2]) != nil, Int(m[3]) != nil, Int(m[4]) != nil else {
                throw KVCacheSerializerError.reconstructionFailed(
                    "RotatingKVCache metaState has non-integer field(s)")
            }
            guard m[1] != "None", Int(m[1]) != nil else {
                throw KVCacheSerializerError.reconstructionFailed(
                    "RotatingKVCache requires an integer maxSize (got '\(m[1])')")
            }
        default:
            throw KVCacheSerializerError.unsupportedCacheType(className)
        }
    }

    // MARK: - Reconstruction

    private static func reconstruct(
        className: String, arrays: [MLXArray], metaState: [String]
    ) throws -> any KVCache {
        // Pre-validate metaState: the engine's setters fatalError on bad
        // input (uncatchable), so a malformed stale/foreign file must
        // become a throw (cold miss), never a process crash.
        try validateMetaState(className: className, metaState)
        // The state setters (KVCacheSimple/RotatingKVCache) ALSO fatalError
        // unless given exactly 2 arrays; deserialize only checks the
        // AGGREGATE chunk count, so a foreign file could place 1 or 3 arrays
        // in one layer. Require 0 (empty cache → setter skipped below) or 2.
        guard arrays.isEmpty || arrays.count == 2 else {
            throw KVCacheSerializerError.reconstructionFailed(
                "\(className) expects 0 or 2 state arrays, got \(arrays.count)")
        }
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
