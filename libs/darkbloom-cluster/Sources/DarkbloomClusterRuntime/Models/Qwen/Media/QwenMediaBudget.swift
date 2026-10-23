import DarkbloomClusterProtocol
import Foundation

/// Additional request owners only. The caller retains the complete original
/// text request/page/lookahead allowance and its existing activation floor.
/// Rank zero serializes tower invocations; every admitted lane retains its own
/// prepared values/features/positions until the producing task and GPU drain.
struct QwenMediaBudget: Equatable {
    let hostBytes: Int
    let nativeBytes: Int
    let largestBufferBytes: Int
    let totalBytes: Int

    init(media: ClusterQwenMedia, rank: Int, hiddenSize: Int, featureElementBytes: Int,
         maximumVideoPatches: Int,
         tensorParallel: Bool, chunkTokens: Int, minimumActivationBytes: Int,
         maximumBufferBytes: Int, sealedFrameOverhead: Int,
         allocationBound: (Int) throws -> Int) throws {
        try media.validateStructure()
        guard (0...1).contains(rank), hiddenSize > 0, [2, 4].contains(featureElementBytes),
            chunkTokens > 0, chunkTokens <= ClusterWorkerLimits.wirePromptTokens,
            maximumVideoPatches > 0, minimumActivationBytes >= 0, maximumBufferBytes > 0,
            sealedFrameOverhead >= 0 else {
            throw ProbeError("Invalid Qwen media memory geometry")
        }
        let activeChunk = min(chunkTokens, media.promptLength)
        func product(_ values: [Int]) throws -> Int {
            var value = 1
            for n in values {
                let next = value.multipliedReportingOverflow(by: n)
                guard n >= 0, !next.overflow, next.partialValue <= ClusterWorkerLimits.capacityBytes else {
                    throw ProbeError("Qwen media memory product exceeds capacity")
                }
                value = next.partialValue
            }
            return value
        }
        func sum(_ values: [Int]) throws -> Int {
            var value = 0
            for n in values {
                let next = value.addingReportingOverflow(n)
                guard n >= 0, !next.overflow, next.partialValue <= ClusterWorkerLimits.capacityBytes else {
                    throw ProbeError("Qwen media memory sum exceeds capacity")
                }
                value = next.partialValue
            }
            return value
        }
        var largestNative = 0
        func allocated(_ logical: Int, count: Int = 1, native: Bool = true) throws -> Int {
            guard logical >= 0, count >= 0 else { throw ProbeError("Invalid Qwen media allocation") }
            guard logical > 0, count > 0 else { return 0 }
            let bytes = try allocationBound(logical)
            guard bytes >= logical, bytes <= ClusterWorkerLimits.capacityBytes,
                !native || bytes <= maximumBufferBytes else {
                throw ProbeError("Qwen media allocator bound is invalid or exceeds the native buffer ceiling")
            }
            if native { largestNative = max(largestNative, bytes) }
            return try product([bytes, count])
        }
        let bound = try media.memory(hiddenSize: hiddenSize, elementBytes: featureElementBytes)
        let hostPositions = try allocated(bound.positionBytes, native: false)
        let positions = try sum([allocated(bound.positionBytes), allocated(product([3, activeChunk, 4]))])
        var retainedFeatures = 0
        if rank == 0 || tensorParallel {
            for item in media.items {
                let full = try product([item.tokenCount, hiddenSize, featureElementBytes])
                if tensorParallel {
                    // Source + assembled result + independently owned transfer
                    // pieces. Bound each piece, not one rounded sum of them.
                    var pieces = 0
                    for lower in stride(from: 0, to: item.tokenCount, by: activeChunk) {
                        pieces = try sum([pieces, allocated(product([
                            min(activeChunk, item.tokenCount - lower), hiddenSize, featureElementBytes]))])
                    }
                    retainedFeatures = try sum([retainedFeatures, allocated(full, count: 2), pieces])
                } else { retainedFeatures = try sum([retainedFeatures, allocated(full)]) }
            }
        }
        // The gathered two-rank output and each authenticated frame remain
        // covered even when tag overhead crosses an allocation boundary.
        let frame = tensorParallel ? try sum([product([activeChunk, hiddenSize, 4, 2]), sealedFrameOverhead]) : 0
        let featureTransfer = try allocated(frame, count: 8)
        let hostTransfer = try allocated(frame, count: 8, native: false)
        if rank == 1 {
            hostBytes = try sum([hostPositions, hostTransfer])
            nativeBytes = try sum([positions, retainedFeatures, featureTransfer])
        } else {
            let largestRaster = try media.items.map {
                try allocated(product([$0.decodedPixels, $0.kind == .video ? 8 : 1, 4, 4]), native: false)
            }.max() ?? 0
            let patches = bound.largestTowerPatches
            let largestPatch = try allocated(product([patches, ClusterQwenMedia.patchWidth, 4]))
            let processingPatches = media.items.contains(where: { $0.kind == .video })
                ? max(patches, maximumVideoPatches) : patches
            let processingScratch = try allocated(product([processingPatches, ClusterQwenMedia.patchWidth, 4]), count: 4, native: false)
            let sourcePatches = try sum(media.items.map {
                try allocated(product([$0.tokenCount, 4, ClusterQwenMedia.patchWidth, 4]), native: false)
            })
            let encoded = try sum(media.items.map { try allocated($0.byteCount, count: 3, native: false) })
            // Preserve the conservative quadratic score/probability allowance
            // and floor; each possible native allocation is rounded separately.
            let tower = try sum([
                allocated(product([patches, patches, 16, 2]), count: 2),
                allocated(product([patches, 1152, 4]), count: 16),
                allocated(product([patches, 4304, 4]), count: 6),
                allocated(product([patches / 4, hiddenSize, 4]), count: 4), largestPatch])
            hostBytes = try sum([encoded, largestRaster, sourcePatches,
                processingScratch, hostPositions, hostTransfer])
            nativeBytes = try sum([positions, retainedFeatures, featureTransfer,
                max(minimumActivationBytes, tower), largestPatch])
        }
        largestBufferBytes = largestNative
        totalBytes = try sum([hostBytes, nativeBytes])
    }
}
