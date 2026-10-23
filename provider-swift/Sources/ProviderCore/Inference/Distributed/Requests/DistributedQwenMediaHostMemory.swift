import Foundation
import DarkbloomClusterProtocol

/// Provider host buffers only. Native text state, tower/feature arrays and
/// collective buffers remain part of each rank's separate live request quote.
enum DistributedQwenMediaHostMemory {
    struct Item: Sendable {
        let kind: ClusterQwenMedia.Kind
        let decodedPixels: Int
        let maximumPatches: Int
    }
    enum Failure: Error { case invalidGeometry, overflow }

    /// Conservative transport envelope: original/decoded sources, JSON/base64
    /// construction, command preflight, owner writer and local worker pipe can
    /// coexist. Keep eight complete bounded command buffers, plus bounded
    /// prompt/template/position host arrays; do not refund on a pipe write.
    static let wireBytes = UInt64(ClusterWorkerLimits.mediaCommandBytes) * 8
        + UInt64(ClusterWorkerLimits.wirePromptTokens) * 64

    static func processingBytes(_ items: [Item], maximumPromptTokens: Int) throws -> UInt64 {
        guard !items.isEmpty, items.count <= ClusterQwenMedia.maximumImages + ClusterQwenMedia.maximumVideos,
            (1...ClusterWorkerLimits.wirePromptTokens).contains(maximumPromptTokens) else {
            throw Failure.invalidGeometry
        }
        var total = try multiply(UInt64(maximumPromptTokens), 64)
        var imagePixels = 0, videoPixels = 0, images = 0, videos = 0
        for item in items {
            let prior = item.kind == .image ? imagePixels : videoPixels
            guard (1...ClusterQwenMedia.maximumItemPixels).contains(item.decodedPixels),
                item.decodedPixels <= ClusterQwenMedia.maximumKindPixels - prior,
                item.maximumPatches > 0 else { throw Failure.invalidGeometry }
            if item.kind == .image { imagePixels += item.decodedPixels; images += 1 }
            else { videoPixels += item.decodedPixels; videos += 1 }
            // The ordinary prompt processor retains all decoded images and
            // accumulated processed videos. Charge all eight source frames per
            // clip, not just the last frame or the claimed final wire grid.
            let frames: UInt64 = item.kind == .image ? 1 : 8
            total = try add(total, multiply(multiply(UInt64(item.decodedPixels), frames), 16))
            // Normalized pixels, patchification, concatenation and descriptor
            // hashing can overlap. Each is float32 at the registered width.
            total = try add(total, multiply(UInt64(item.maximumPatches), UInt64(ClusterQwenMedia.patchWidth * 4 * 4)))
        }
        guard images <= ClusterQwenMedia.maximumImages, videos <= ClusterQwenMedia.maximumVideos else {
            throw Failure.invalidGeometry
        }
        return total
    }

    private static func multiply(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let value = a.multipliedReportingOverflow(by: b)
        guard !value.overflow, value.partialValue <= UInt64(ClusterWorkerLimits.capacityBytes) else { throw Failure.overflow }
        return value.partialValue
    }
    private static func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let value = a.addingReportingOverflow(b)
        guard !value.overflow, value.partialValue <= UInt64(ClusterWorkerLimits.capacityBytes) else { throw Failure.overflow }
        return value.partialValue
    }
}
