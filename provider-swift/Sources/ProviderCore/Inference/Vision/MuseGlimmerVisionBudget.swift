// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer
import ProviderCoreFoundation

/// Unified-memory and KV reservation for one Muse Glimmer image request,
/// charged by the scheduler's `VisionMemoryGate` before any decode and
/// released once the features are evaluated, just before submit (where the
/// bridge reserves the real prompt's KV itself).
///
/// Every image is charged its ceiling, `maximumPromptTokensPerImage` (4,098
/// tokens: 4,096 patches merged 2 × 2 plus its two framing tokens), whatever
/// its size, so no image is under-reserved before its header is read.
enum MuseGlimmerVisionBudget {
    /// Patches of the largest image: 4,096 merged tokens of 2 × 2 patches.
    static let maximumPatches = MuseGlimmerVisionPolicy.maximumImageTokens * 4
    /// Values of one patch row: temporal 2 × channels 3 × 14 × 14.
    static let patchValues = 1_176
    /// The pinned stack's widths (`config.json`, cross-checked at load).
    static let visionHidden = 1_536
    static let visionIntermediate = 8_960
    static let mergedWidth = 6_144
    static let projectorHidden = 4_096
    /// Text width: every feature row the encoder returns.
    static let featureWidth = 6_656

    struct Reservation: Equatable {
        /// The tower's working set for the largest image (images run one at
        /// a time) plus every image's evaluated features, which stay live
        /// until submit. Decode rasters are the caller's
        /// (`MediaIngest.projectedDecodeBytes`).
        let bytes: UInt64
        /// Prompt text, each image at its ceiling, and the output.
        let kvTokens: Int
    }

    static func imageCount(_ request: OpenAIChatCompletionRequest) -> Int {
        request.messages.reduce(0) { count, message in
            guard case .parts(let parts) = message.content else { return count }
            return count + parts.reduce(0) { if case .imageURL = $1 { return $0 + 1 }; return $0 }
        }
    }

    /// An analytic upper bound, charged at 4 bytes per element although the
    /// stack runs in BF16, of what is live while the tower encodes one image
    /// of `patches` patches: float32 pixels and their cast, the resized
    /// raster, the residual stream and its norm, QKV with its head-major
    /// copies padded from 96 to 128, the attention output and projection,
    /// both GELU MLP activations, and the adapter and projection over the
    /// merged rows. Attention is fused, so no patch-squared score exists.
    /// Not a measurement: qualification measures the real peak (D13).
    static func towerWorkingSetBytes(patches: Int = maximumPatches) -> UInt64 {
        let n = UInt64(max(0, patches))
        let merged = n / 4
        let paddedHeads = UInt64(16 * 128)
        let elements: [UInt64] = [
            2 * n * UInt64(patchValues),
            n * 4 * 14 * 14,
            2 * n * UInt64(visionHidden),
            3 * n * UInt64(visionHidden) + 3 * n * paddedHeads,
            n * paddedHeads + n * UInt64(visionHidden),
            2 * n * UInt64(visionIntermediate) + n * UInt64(visionHidden),
            merged * UInt64(mergedWidth + 2 * projectorHidden + featureWidth),
        ]
        return sum(elements.map { multiplied($0, 4) })
    }

    /// BF16 features of `images` images at their ceiling.
    static func featureBytes(images: Int) -> UInt64 {
        multiplied(UInt64(max(0, images)),
            UInt64(MuseGlimmerVisionPolicy.maximumImageTokens * featureWidth * 2))
    }

    static func reservation(
        request: OpenAIChatCompletionRequest, defaultMaxTokens: Int, contextLength: Int
    ) -> Reservation {
        let images = imageCount(request)
        // `projectedKVTokens` allots `visionTokensPerImage` (1,024) per image.
        let extraPerImage = max(
            0, MuseGlimmerVisionPolicy.maximumPromptTokensPerImage - MediaIngest.visionTokensPerImage)
        let base = MediaIngest.projectedKVTokens(
            request, defaultMaxTokens: defaultMaxTokens, contextLength: contextLength)
        let (extra, extraOverflow) = images.multipliedReportingOverflow(by: extraPerImage)
        var (tokens, overflow) = base.addingReportingOverflow(extra)
        if extraOverflow || overflow { tokens = .max }
        if contextLength > 0 {
            let output = max(0, MediaIngest.resolveMaxOutputTokens(
                for: request, defaultMaxTokens: defaultMaxTokens))
            let (ceiling, ceilingOverflow) = contextLength.addingReportingOverflow(output)
            if !ceilingOverflow { tokens = min(tokens, ceiling) }
        }
        let bytes = images > 0 ? sum([towerWorkingSetBytes(), featureBytes(images: images)]) : 0
        return .init(bytes: bytes, kvTokens: tokens)
    }

    private static func multiplied(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (product, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? .max : product
    }

    private static func sum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            return overflow ? .max : sum
        }
    }
}
