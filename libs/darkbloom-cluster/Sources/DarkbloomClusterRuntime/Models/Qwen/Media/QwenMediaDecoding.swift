import CoreImage
import CryptoKit
import DarkbloomClusterProtocol
import Foundation
import ImageIO
import MLX
import MLXLMCommon
import MLXVLM

/// The provider's full-image/EXIF and owned-video decode policy, evaluated on
/// CPU before rank zero's tower. Encoded buffers, rasters and prepared patches
/// remain covered by the native request supplement until checked retirement.
///
/// The patches are computed on a CPU stream of this preparation's own
/// (`Stream.withNewDefaultStream`), never the process's shared CPU stream:
/// MLX evaluates one thread's graph while another thread schedules (the
/// evaluation lock covers scheduling only), and a stream's stored task error
/// is thrown to whichever caller synchronizes that stream next, so sharing a
/// stream with the executor's collectives lets either side fail the other.
enum QwenMediaDecoding {
    static let maximumPixels = 100_000_000
    static let maximumAggregatePixels = 384_000_000
    static let maximumDuration: Double = 600

    static func prepare(_ media: ClusterQwenMedia, modelConfiguration: Data,
                        processorConfiguration: Data) async throws -> [[Float]] {
        try media.verifyEncodedBytes()
        guard ClusterQwenMedia.sha256(modelConfiguration) == media.configurationSHA256,
            ClusterQwenMedia.sha256(processorConfiguration) == media.processorSHA256,
            media.processorPolicy.rawValue == Qwen3VLMediaProcessor.policyID else {
            throw ProbeError("Qwen media processor bytes differ")
        }
        return try await Stream.withNewDefaultStream(device: .cpu) {
            try await MLX.withError { errors in
                let processor = try Qwen3VLMediaProcessor(modelConfiguration: modelConfiguration,
                    processorConfiguration: processorConfiguration)
                var result: [[Float]] = [], imagePixels = 0, videoPixels = 0
                for item in media.items {
                    try Task.checkCancellation()
                    guard let data = item.encoded else { throw ProbeError("Missing Qwen encoded media") }
                    let pixels: MLXArray, grid: THW
                    switch item.kind {
                    case .image:
                        let decoded = try image(data, expectedPixels: item.decodedPixels)
                        imagePixels = try addPixels(imagePixels, decoded.pixels)
                        let extent = decoded.image.extent.size
                        let planned = try processor.imageGrid(height: Int(extent.height), width: Int(extent.width))
                        guard planned.t == item.temporal, planned.h == item.height, planned.w == item.width else {
                            throw ProbeError("Qwen image grid differs before patch allocation")
                        }
                        (pixels, grid) = try processor.preprocess(images: [decoded.image], processing: nil)
                    case .video:
                        let owned = try MemoryBackedVideoAsset(videoData: data)
                        let metadata = try await MediaProcessing.metadata(for: owned)
                        let framePixels = try Self.videoPixels(metadata)
                        guard framePixels == item.decodedPixels else {
                            throw ProbeError("Qwen video raster differs from its authenticated bound")
                        }
                        videoPixels = try addPixels(videoPixels, framePixels)
                        (pixels, grid) = try await processor.preprocess(video: .memoryBacked(owned))
                    }
                    try Task.checkCancellation(); try errors.check()
                    guard grid.t == item.temporal, grid.h == item.height, grid.w == item.width,
                        pixels.shape == [item.tokenCount * 4, ClusterQwenMedia.patchWidth],
                        pixels.dtype == .float32 else {
                        throw ProbeError("Qwen prepared patches differ from the authenticated grid")
                    }
                    eval(pixels); Stream.cpu.synchronize(); try errors.check()
                    let values = pixels.asArray(Float.self)
                    try errors.check(); try Task.checkCancellation()
                    guard values.allSatisfy(\.isFinite), digest(values) == item.patchesSHA256 else {
                        throw ProbeError("Qwen prepared patch bytes differ from the leader")
                    }
                    result.append(values)
                }
                return result
            }
        }
    }
    static func digest(_ values: [Float]) -> String {
        // Apple Silicon is little-endian; spell the wire order explicitly.
        var hash = SHA256()
        for value in values { var word = value.bitPattern.littleEndian
            withUnsafeBytes(of: &word) { hash.update(data: Data($0)) } }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func addPixels(_ current: Int, _ amount: Int) throws -> Int {
        guard amount > 0, amount <= maximumAggregatePixels - current else {
            throw ProbeError("Qwen decoded media exceeds its aggregate pixel bound")
        }
        return current + amount
    }
    private static func pixels(_ size: CGSize) throws -> Int {
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
            size.width < CGFloat(Int.max), size.height < CGFloat(Int.max) else {
            throw ProbeError("Qwen media has unreadable pixel dimensions")
        }
        let count = Int(size.width).multipliedReportingOverflow(by: Int(size.height))
        guard !count.overflow, count.partialValue > 0, count.partialValue <= maximumPixels else {
            throw ProbeError("Qwen media exceeds its pixel bound")
        }
        return count.partialValue
    }
    static func image(_ data: Data, expectedPixels: Int) throws -> (image: CIImage, pixels: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ProbeError("Qwen image dimensions are unreadable")
        }
        let declared = try pixels(CGSize(width: width, height: height))
        guard declared <= expectedPixels, expectedPixels <= maximumPixels else {
            throw ProbeError("Qwen image raster exceeds its authenticated bound")
        }
        // Decode index zero, never a thumbnail, and apply EXIF exactly as the
        // existing provider. Unknown dimensions refuse before raster allocation.
        let decoded: CIImage
        if let full = CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCache: true] as CFDictionary) {
            var image = CIImage(cgImage: full)
            if let raw = properties[kCGImagePropertyOrientation] as? UInt32,
                let orientation = CGImagePropertyOrientation(rawValue: raw) {
                image = image.oriented(orientation)
            }
            decoded = image
        } else if let image = CIImage(data: data, options: [.applyOrientationProperty: true]) {
            decoded = image
        } else { throw ProbeError("Qwen image does not decode") }
        let actual = try pixels(decoded.extent.size)
        guard max(declared, actual) == expectedPixels else {
            throw ProbeError("Qwen image raster differs from its authenticated bound")
        }
        let origin = decoded.extent.origin
        let normalized = origin == .zero ? decoded : decoded.transformed(
            by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        return (normalized, max(declared, actual))
    }
    private static func videoPixels(_ metadata: VideoMetadata) throws -> Int {
        try Task.checkCancellation()
        guard metadata.duration.seconds.isFinite, metadata.duration.seconds > 0,
            metadata.duration.seconds <= maximumDuration, !metadata.tracks.isEmpty else {
            throw ProbeError("Qwen video duration or tracks exceed their bounds")
        }
        var maximum = 0
        for track in metadata.tracks {
            guard !track.decodedFrameDimensions.isEmpty else {
                throw ProbeError("Qwen video coded dimensions are unreadable")
            }
            if let natural = track.naturalSize { maximum = max(maximum, try pixels(natural)) }
            for size in track.decodedFrameDimensions { maximum = max(maximum, try pixels(size)) }
        }
        return maximum
    }
}
