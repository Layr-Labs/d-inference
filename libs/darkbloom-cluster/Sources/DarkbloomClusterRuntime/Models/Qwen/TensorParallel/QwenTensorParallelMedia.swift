import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLMCommon
import MLXVLM

/// Rank zero owns preprocessing and one complete visual subject at a time.
/// Every feature row crosses the existing sealed all-gather without arithmetic;
/// both ranks keep the same feature dtype/bits and independently derived MRoPE.
enum QwenTensorParallelMedia {
    static func prepare(_ work: QwenMediaRequestWork, vision: QwenStageVision?,
        inventory: QwenStageVisionInventory, modelConfiguration: Data,
        rank: Int, group: QwenTensorParallelGroup, chunkTokens: Int,
        shouldStop: () -> Bool, check: () throws -> Void) throws {
        guard group.sealed != nil, group.requiresSealing, chunkTokens > 0,
            (rank == 0) == (vision != nil) else {
            throw ProbeError("Qwen media requires a sealed pair with one rank-zero tower")
        }
        let media = work.state.media
        if rank == 0 {
            let processorConfiguration = inventory.processorConfiguration
            try work.preparation.start {
                try await QwenMediaDecoding.prepare(media, modelConfiguration: modelConfiguration,
                    processorConfiguration: processorConfiguration)
            }
        }
        var stopped = false
        // An agreed poll keeps the follower alive while AVFoundation prepares
        // CPU patches. A stop asks the task to unwind, then waits for proof of
        // host release before either rank can leave this protocol phase.
        while true {
            stopped = stopped || shouldStop()
            if stopped { work.preparation.cancel() }
            let outcome = work.preparation.outcome
            let local: [Int32] = [rank == 1 || work.preparation.finished ? 1 : 0,
                rank == 0 && outcome == .failed ? 1 : 0, stopped ? 1 : 0]
            let status = try group.exchangeIntegers(local)
            try check()
            guard status.count == 3 else { throw ProbeError("Qwen media preparation status differs") }
            stopped = stopped || status[2] != 0
            if stopped { work.preparation.cancel() }
            if status[0] == 2 {
                guard !stopped, status[1] == 0 else {
                    throw ProbeError("Qwen media preparation failed or was cancelled")
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        var prepared = rank == 0 ? try work.preparation.take() : []
        defer { prepared.removeAll() }
        var features: [MLXArray] = []
        for (index, item) in media.items.enumerated() {
            var source: MLXArray?
            var failed = false
            if rank == 0 {
                do {
                    guard prepared.indices.contains(index), let vision else {
                        throw ProbeError("Qwen media preparation lost a complete subject")
                    }
                    let patches = MLXArray(prepared[index], [item.tokenCount * 4, ClusterQwenMedia.patchWidth])
                    work.roots.append(patches)
                    let grid = THW(item.temporal, item.height, item.width)
                    let value = try vision.tower.visionFeatures(
                        imagePixels: item.kind == .image ? patches : nil,
                        imageGrids: item.kind == .image ? [grid] : nil,
                        videoPixels: item.kind == .video ? patches : nil,
                        videoGrids: item.kind == .video ? [grid] : nil).flattenedFeatures
                    work.roots.append(value)
                    eval(value); Stream.gpu.synchronize(); try check()
                    guard value.shape == [item.tokenCount, work.state.hiddenSize],
                        value.dtype == work.state.featureDType else {
                        throw ProbeError("Qwen tower output differs from admitted feature geometry")
                    }
                    source = value
                } catch { failed = true }
            }
            let ready = try group.exchangeIntegers([failed ? 1 : 0, shouldStop() ? 1 : 0])
            try check()
            guard ready == [0, 0] else { throw ProbeError("Qwen tower failed or the peer stopped media preparation") }
            var pieces: [MLXArray] = []
            for lower in stride(from: 0, to: item.tokenCount, by: chunkTokens) {
                let upper = min(item.tokenCount, lower + chunkTokens), count = upper - lower
                let input = rank == 0 ? source![lower..<upper, 0...].expandedDimensions(axis: 0)
                    : MLXArray.zeros([1, count, work.state.hiddenSize], dtype: work.state.featureDType)
                let gathered = group.allGather(input)
                work.roots.append(gathered)
                eval(gathered); Stream.gpu.synchronize(); try check()
                let owned = try copySelectedTensor(gathered[0, 0..<count, 0...], selection: .all)
                work.roots.append(owned); pieces.append(owned)
                try check()
                // The gather/copy has drained; keep only the complete prior
                // subjects, this subject's source and owned output pieces.
                work.roots = features + (source.map { [$0] } ?? []) + pieces
            }
            let feature = pieces.count == 1 ? pieces[0] : concatenated(pieces, axis: 0)
            work.roots.append(feature)
            eval(feature); Stream.gpu.synchronize(); try check()
            features.append(feature)
            // The completed feature is still held by `features`; discard all
            // prior patch/transport roots only after the last checked drain.
            work.roots = features
            if rank == 0 { prepared[index].removeAll() }
        }
        try work.state.installFeatures(features)
        guard work.preparation.releaseIfFinished() else {
            throw ProbeError("Qwen media host preparation did not retire")
        }
        work.roots.removeAll()
    }
}
