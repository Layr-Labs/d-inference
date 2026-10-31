import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLMCommon
import MLXVLM

/// Rank zero owns preprocessing and one complete visual subject at a time.
/// Every feature row crosses the existing sealed all-gather without arithmetic;
/// both ranks keep the same feature dtype/bits and independently derived MRoPE.
///
/// Rank zero prepares a request's patches at admission, before it answers
/// (`admit`): a preparation that cannot reproduce the leader's patches
/// refuses that request alone, as any other reservation check does. The
/// lanes that run are untouched and the owner gives back rank one's
/// admission. The joined request then runs the tower and carries the features
/// across (`prepare`).
enum QwenTensorParallelMedia {
    /// Rank zero, on the native executor at reservation. The patches are
    /// decoded and checked against the leader's digests on their own task
    /// while this executor waits, so no other MLX work of this worker runs
    /// meanwhile, and they stay host values (`QwenMediaPreparation`) until the
    /// request joins. Throws `ClusterResidentRequestRefusal` for this request
    /// alone, with the preparation's own reason, after its task has ended.
    static func admit(_ work: QwenMediaRequestWork, modelConfiguration: Data, processorConfiguration: Data,
        deadline: UInt64, now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) throws {
        let media = work.state.media
        try work.preparation.start {
            try await QwenMediaDecoding.prepare(media, modelConfiguration: modelConfiguration,
                processorConfiguration: processorConfiguration)
        }
        // Past the request's deadline the task is asked to stop; its host
        // bytes stay charged until it ended (`QwenMediaPreparation`).
        while !work.preparation.finished {
            if now() >= deadline { work.preparation.cancel() }
            Thread.sleep(forTimeInterval: 0.001)
        }
        guard work.preparation.outcome != .prepared else { return }
        let cause = work.preparation.error.map { String(describing: $0) } ?? "cancelled at its deadline"
        _ = work.preparation.releaseIfFinished()
        let reason: ClusterWorkerRefusal = now() >= deadline ? .deadline : .unsupported
        let message = "Qwen media preparation refused this request: \(cause.prefix(240))"
        log("darkbloom-request-refused-v1 rank=0 reason=\(reason.rawValue)")
        log("darkbloom-cluster-worker: \(message) (the pair keeps serving)")
        throw ClusterResidentRequestRefusal(reason: reason, message: message)
    }

    /// Both ranks, when the joined request opens. Rank zero's patches were
    /// prepared at admission; it runs the tower one subject at a time and both
    /// ranks carry each subject's features across the sealed all-gather.
    static func prepare(_ work: QwenMediaRequestWork, vision: QwenStageVision?, rank: Int,
        group: QwenTensorParallelGroup, chunkTokens: Int, check: () throws -> Void) throws {
        guard group.sealed != nil, group.requiresSealing, chunkTokens > 0,
            (rank == 0) == (vision != nil) else {
            throw ProbeError("Qwen media requires a sealed pair with one rank-zero tower")
        }
        let media = work.state.media
        // Both ranks learn together whether rank zero holds its admitted patches.
        let unprepared = rank == 0 && work.preparation.outcome != .prepared ? Int32(1) : 0
        let status = try group.exchangeIntegers([unprepared])
        try check()
        guard status == [0] else { throw ProbeError("Qwen media patches are missing on rank zero") }
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
                } catch {
                    failed = true
                    log("darkbloom-cluster-worker: Qwen media tower failed: \(String(describing: error).prefix(240))")
                }
            }
            let ready = try group.exchangeIntegers([failed ? 1 : 0])
            try check()
            guard ready == [0] else { throw ProbeError("Qwen tower failed on rank zero") }
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
