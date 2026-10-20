import DarkbloomClusterProtocol
import Foundation
import MLX

/// The link measured at load, the way the sharded modes use it, in a few
/// hundred milliseconds and before any weight is read: point-to-point records
/// (a small one, as a pipeline's decode hand-off is, and a large one, as a
/// prefill chunk's is) and the sealed all-sum at a decode step's width and at
/// a prefill chunk's. Medians of a few repetitions, both ranks in lockstep.
/// The ready record carries it; the pair's owner keeps the latest per pair and
/// the planner turns it into link costs (`ClusterLinkCosts(probe:)`). Each
/// load measures it again, so a re-plan always uses the link as it is now.
enum QwenTensorParallelLinkProbe {
    static let largePointToPointBytes = 4 << 20

    static func measure(collective: Collective, group: QwenTensorParallelGroup, hiddenSize: Int, chunkTokens: Int,
                        check: () throws -> Void) throws -> ClusterWorkerLinkProbe {
        func median(_ values: [UInt64]) -> Int { Int(values.sorted()[values.count / 2] / 1000) }
        func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
        // Point to point, small: the keep-warm exchange (one 64-byte record each way).
        var small: [UInt64] = []
        for _ in 0..<9 { small.append(try ClusterKeepWarm.dataPlanePing(collective: collective, check: check) / 2) }
        // Point to point, large: one 4 MiB array each way.
        let rank = collective.rank, peer = 1 - rank, count = largePointToPointBytes / 4
        let mine = MLXArray.zeros([count], dtype: .float32)
        eval(mine)
        var large: [UInt64] = []
        for index in 0..<3 {
            let started = now()
            func send() throws {
                _ = try collective.sendCompleted(mine, to: peer, maximumBytes: largePointToPointBytes,
                    scope: .session(.keepWarm, "link-probe-\(index)-rank\(rank)"), check: check)
            }
            func receive() throws {
                _ = try collective.receiveCompleted(shape: [count], dtype: .float32, from: peer,
                    maximumBytes: largePointToPointBytes, scope: .session(.keepWarm, "link-probe-\(index)-rank\(peer)"), check: check)
            }
            if rank == 0 { try send(); try receive() } else { try receive(); try send() }
            large.append((now() - started) / 2)
        }
        // The sealed all-sum (the native one on a plaintext data plane), as a
        // ready tensor-parallel rank runs it: with its bounded freed-buffer
        // cache and after one unmeasured pass. A load runs with MLX's cache at
        // zero, where every repetition would first-touch fresh temporaries
        // (measured: 32 MiB sealed sum 16.9 ms cold against 7.2 ms ready).
        let previousCacheLimit = Memory.cacheLimit
        Memory.cacheLimit = max(previousCacheLimit, QwenTensorParallelLaunch.freedBufferCacheBytes(
            allocatorHeadroomBytes: QwenDenseStageLoadPolicy.allocatorHeadroomBytes))
        defer { Memory.cacheLimit = previousCacheLimit; Memory.clearCache() }
        func allSum(_ elements: Int, _ repetitions: Int) throws -> Int {
            let value = MLXArray.zeros([elements], dtype: .float32)
            eval(value)
            var times: [UInt64] = []
            for index in 0...repetitions {
                try check()
                let started = now()
                let summed = group.allSum(value)
                try MLX.withError { error in eval(summed); try error.check() }
                if index > 0 { times.append(now() - started) }
            }
            return median(times)
        }
        let smallElements = max(1, hiddenSize), largeElements = max(1, hiddenSize * max(1, chunkTokens))
        let smallSum = try allSum(smallElements, 21), largeSum = try allSum(largeElements, 3)
        return ClusterWorkerLinkProbe(transport: collective.transport.rawValue, keyed: group.sealed != nil,
            pointToPointSmallBytes: 64, pointToPointSmallMicroseconds: max(1, median(small)),
            pointToPointLargeBytes: largePointToPointBytes, pointToPointLargeMicroseconds: max(1, median(large)),
            allSumSmallBytes: smallElements * 4, allSumSmallMicroseconds: max(1, smallSum),
            allSumLargeBytes: largeElements * 4, allSumLargeMicroseconds: max(1, largeSum))
    }

    /// Bound in a pipeline load's agreement: both ranks measure the link before reading a weight.
    static let loadAgreementField = "darkbloom-link-probe-v1"

    /// The same probe on a pipeline (or any non-tensor-parallel) load's JACCL
    /// collective: a reduction group borrowed for the probe only and, on a
    /// keyed data plane, sealed with the tensor-parallel keys the pinned
    /// exchange derived for this load (`tensorParallelSeal`), so no byte
    /// crosses in the clear and the figure is the one tensor parallel would pay.
    static func measure(onPipeline collective: Collective, keyed: Bool, loadAgreement: String, hiddenSize: Int, chunkTokens: Int,
                        check: () throws -> Void) throws -> ClusterWorkerLinkProbe {
        let group = try QwenTensorParallelGroup(collective: collective)
        if keyed {
            let codec = try QwenTensorParallelSealCodec.product(collective: collective, scope: Data(loadAgreement.utf8))
            try codec.install()
            group.sealed = codec
        }
        return try measure(collective: collective, group: group, hiddenSize: hiddenSize, chunkTokens: chunkTokens, check: check)
    }

    static func line(_ p: ClusterWorkerLinkProbe, rank: Int) -> String {
        "darkbloom-link-probe-v1 rank=\(rank) transport=\(p.transport) keyed=\(p.keyed ? 1 : 0)"
            + " p2p_small_bytes=\(p.pointToPointSmallBytes) p2p_small_us=\(p.pointToPointSmallMicroseconds)"
            + " p2p_large_bytes=\(p.pointToPointLargeBytes) p2p_large_us=\(p.pointToPointLargeMicroseconds)"
            + " allsum_small_bytes=\(p.allSumSmallBytes) allsum_small_us=\(p.allSumSmallMicroseconds)"
            + " allsum_large_bytes=\(p.allSumLargeBytes) allsum_large_us=\(p.allSumLargeMicroseconds)"
    }
}
