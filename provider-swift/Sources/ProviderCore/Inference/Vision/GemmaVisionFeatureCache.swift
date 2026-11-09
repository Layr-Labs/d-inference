import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import MLXVLM

/// Hash decoded payload bytes while MediaIngest already owns them. No second
/// base64 decode, raw-byte retention, prompt capture or exposed digest metrics.
final class VisionImageIdentityCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var digests: [Data] = []
    func record(_ data: Data) {
        lock.withLock {
            // Capture is optional. More than 64 consumed images cannot match
            // this bounded identity list and therefore run entirely cold.
            if digests.count < 64 { digests.append(Data(SHA256.hash(data: data))) }
        }
    }
    var values: [Data] { lock.withLock { digests } }
}

extension EngineV2VisionPrefill {
    /// The loaded processor is immutable for a bridge lifetime. Bind its actual
    /// artifact metadata and implementation policy as well as normalized pixels.
    /// Unresolved, changed-in-place or nonstandard processor assets fail cold.
    static func gemmaProcessorIdentity(ctx: ModelContext,
                                       transaction: VisionFeatureCache.Transaction) -> String? {
        guard ctx.processor is Gemma4Processor,
            case .directory(let directory) = ctx.configuration.id,
            let scratch = transaction.scratch(byteCount: 256 * 1024) else { return nil }
        return withExtendedLifetime(scratch) {
            guard let fingerprint = GemmaVisionProcessorIdentity.fingerprint(
                directory: directory, device: String(describing: Device.defaultDevice())) else { return nil }
            let identity = "\(ObjectIdentifier(ctx.model))/\(fingerprint)"
            guard transaction.bind(identity) else { return nil }
            return fingerprint
        }
    }

    /// Runs entirely under ModelContainer.perform and MLX.withError. Every
    /// snapshot/hydration has fresh request-owned MLX backing; only CPU bytes
    /// can outlive the call. Video and unqualified wrappers use the cold path.
    static func gemmaImageFeatures(
        wrapper: Gemma4, image: LMInput.ProcessedImage,
        transaction: VisionFeatureCache.Transaction?, scope: String?,
        processorIdentity: String?, rawDigests: [Data], mlxErrors: MLX.ErrorBox,
        activity: VisionFeatureCacheActivity
    ) throws -> [MLXArray] {
        guard !wrapper.training, let transaction, let scope, !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            scope.utf8.count <= 1024, let processorIdentity,
            image.pixels.ndim == 4, rawDigests.count == image.pixels.dim(0) else {
            activity.encode(image.pixels.dim(0))
            return wrapper.perImageVisionFeatures(pixels: image.pixels, frames: image.frames)
        }
        var result: [MLXArray] = []
        for index in 0 ..< image.pixels.dim(0) {
            try Task.checkCancellation()
            let frame = image.frames.flatMap { index < $0.count ? $0[index] : nil }
            let height = frame?.h ?? image.pixels.dim(2)
            let width = frame?.w ?? image.pixels.dim(3)
            guard height > 0, width > 0, height <= image.pixels.dim(2), width <= image.pixels.dim(3) else {
                throw EngineV2VisionPrefillError.invalidVisionGrid(mediaIndex: index)
            }
            let pixels = image.pixels[index, 0..., ..<height, ..<width].expandedDimensions(axis: 0)
            var key: VisionFeatureCache.Key?
            // New canonicalization bytes are in addition to the media admission
            // estimate. Budget denial simply skips hashing and retention.
            if let scratch = transaction.scratch(byteCount: pixels.nbytes) {
                key = try withExtendedLifetime(scratch) {
                    eval(pixels)
                    try throwIfMLXFaulted(mlxErrors)
                    let raw = pixels.asData(access: .copy)
                    try throwIfMLXFaulted(mlxErrors)
                    return VisionFeatureCache.Key(scope: scope,
                        model: String(describing: ObjectIdentifier(wrapper)),
                        processor: processorIdentity, dtype: String(describing: pixels.dtype),
                        shape: pixels.shape, frame: [frame?.t ?? 1, height, width],
                        pixelBytes: raw.data, rawDigest: rawDigests[index])
                }
            }
            if let key, let hit = transaction.lookup(key), let dtype = featureDType(hit.dtype),
                let hydrationCharge = transaction.scratch(byteCount: hit.byteCount) {
                let restored = try withExtendedLifetime(hydrationCharge) { try hit.withUnsafeBytes { raw in
                    let bytes = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: raw.baseAddress!),
                        count: raw.count, deallocator: .none)
                    // Charge additional hydration backing before allocation, then
                    // retire this transient charge only after eval makes it visible
                    // to MLX allocator accounting. CPU snapshot charge remains.
                    let value = MLXArray(bytes, hit.shape, dtype: dtype)
                    eval(value)
                    try throwIfMLXFaulted(mlxErrors)
                    return value
                } }
                try Task.checkCancellation()
                activity.hit()
                result.append(restored)
                continue
            }
            activity.encode()
            let features = wrapper.perImageVisionFeatures(
                pixels: pixels, frames: [THW(frame?.t ?? 1, height, width)])
            guard features.count == 1, let feature = features.first else {
                throw EngineV2VisionPrefillError.emptyVisionFeatures(kind: .image)
            }
            eval(feature)
            try throwIfMLXFaulted(mlxErrors)
            try Task.checkCancellation()
            if let key, feature.ndim == 3, feature.dim(0) == 1,
                featureDType(String(describing: feature.dtype)) != nil {
                try transaction.stage(key, dtype: String(describing: feature.dtype),
                    shape: feature.shape, byteCount: feature.nbytes) {
                    let raw = feature.asData(access: .copy)
                    try throwIfMLXFaulted(mlxErrors)
                    guard raw.shape == feature.shape, raw.dType == feature.dtype,
                        raw.data.count == feature.nbytes else {
                        throw EngineV2VisionPrefillError.towerFault(stage: "feature snapshot")
                    }
                    return raw.data
                }
            }
            result.append(feature)
        }
        return result
    }

    private static func featureDType(_ tag: String) -> DType? {
        switch tag {
        case String(describing: DType.float16): return .float16
        case String(describing: DType.bfloat16): return .bfloat16
        case String(describing: DType.float32): return .float32
        default: return nil
        }
    }
}
