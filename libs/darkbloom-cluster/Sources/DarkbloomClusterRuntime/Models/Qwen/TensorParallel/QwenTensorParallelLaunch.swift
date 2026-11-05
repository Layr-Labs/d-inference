import Foundation

/// The launch options both ranks of a tensor-parallel run must share before
/// they load: every option that changes how many collectives run, in which
/// order, or the shape or dtype a collective carries. The first exchange
/// carries `digest` (fixed width, versioned: the same shape in every build),
/// so a mismatched launch, or a rank of another build, is refused on both
/// ranks instead of meeting in an all-sum of different buffers.
public struct QwenTensorParallelLaunch: Equatable, Sendable {
    public var outputCount: Int
    public var chunkSize: Int
    public var promptTokens: Int
    public var repeats: Int
    public var warmup: Bool
    /// Evaluate and synchronize before every all-sum (otherwise lazy).
    public var explicitTiming: Bool
    /// Row-parallel partials summed in bfloat16 (otherwise float32): the
    /// all-sum's dtype and byte count.
    public var bfloat16Partials: Bool
    /// The hybrid's prefill rank; nil for a plain tensor-parallel run.
    public var hybridPrefillRank: Int?
    /// Each rank's share weight (`QwenTensorParallelPlan.shares`): which heads
    /// and channels every rank holds. Ranks with different shares would hold
    /// overlapping or missing heads and sum wrong partials without any
    /// mismatched shape, so the shares are agreed first.
    public var shares: [Int]
    /// Floating all-sums cross the link sealed (`QwenTensorParallelSealCodec`)
    /// instead of the native all-sum: another collective per reduction.
    public var sealedReduction: Bool

    public init(outputCount: Int, chunkSize: Int, promptTokens: Int, repeats: Int, warmup: Bool,
                explicitTiming: Bool, bfloat16Partials: Bool, hybridPrefillRank: Int?, shares: [Int] = [1, 1],
                sealedReduction: Bool = false) {
        self.outputCount = outputCount
        self.chunkSize = chunkSize
        self.promptTokens = promptTokens
        self.repeats = repeats
        self.warmup = warmup
        self.explicitTiming = explicitTiming
        self.bfloat16Partials = bfloat16Partials
        self.hybridPrefillRank = hybridPrefillRank
        self.shares = shares
        self.sealedReduction = sealedReduction
    }

    /// The values the first agreement compares across ranks.
    public var agreement: [Int32] {
        [Int32(clamping: outputCount), Int32(clamping: chunkSize), Int32(clamping: promptTokens),
         Int32(clamping: repeats), warmup ? 1 : 0, explicitTiming ? 2 : 1,
         hybridPrefillRank.map { Int32(clamping: 10 + $0) } ?? 0, bfloat16Partials ? 2 : 1,
         Int32(clamping: shares.count)] + shares.map { Int32(clamping: $0) } + [sealedReduction ? 2 : 1]
    }

    /// Version of the first exchange; change it whenever `agreement` changes
    /// meaning or a build changes the collectives a launch issues (v5: a
    /// routed-expert layer packs its expert and shared partials into one
    /// collective, two per layer instead of three).
    public static let agreementVersion = "darkbloom-tp-launch-v5"

    /// 64-bit FNV-1a of the version and `agreement`: what the ranks compare first.
    public var digest: UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in (Self.agreementVersion + "|" + agreement.map(String.init).joined(separator: ",")).utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        return hash
    }
}

extension QwenTensorParallelLaunch {
    /// The freed-buffer cache a ready tensor-parallel shard keeps. The
    /// dedicated worker loads with MLX's cache at zero (every freed buffer
    /// returned at once, so the memory gate's accounting is exact while
    /// weights load); a decode step then creates its ~1,500 intermediate
    /// buffers through the driver one by one (measured on the M5 Ultra: most
    /// of a 79 ms 27B step in buffer creation). Half of the allocator headroom
    /// the memory gate already demands free beside the reservation, so the
    /// cache never takes memory the gate did not hold back.
    public static func freedBufferCacheBytes(allocatorHeadroomBytes: Int) -> Int {
        max(0, allocatorHeadroomBytes) / 2
    }

    /// A decode forward is submitted to the GPU every this many decoder
    /// layers (`Qwen35LayerSubmission`), so the GPU and the collectives run
    /// the layers already built while the host builds the rest. One layer a
    /// submission spent a commit and a GPU wake-up per layer: on two M5 Ultra
    /// 256 GB over JACCL (27B, sealed sums, one request) a step took 21.4 ms
    /// at stride 1 and 20.2-20.3 ms at 8-16 (25.1 against 19.9-20.4 ms with
    /// the host loaded), 35.4 against 29.5-29.9 ms for four requests, and
    /// 21.2 ms again at 32, where the GPU waits for the host's first batch of
    /// layers. Re-measured on a quieter pair (2026-11-05 19:58Z): 23.2 → 19.7
    /// ms (−15 %) for one request and 32.1 → 27.8 ms (−13 %) for four. 8 is inside that flat band and divides the 9B's 32 and the
    /// 27B's 64 layers. Not a launch option: evaluation
    /// order only, so each rank's logits and committed state keep their bits
    /// at any stride and two ranks need not agree on it.
    public static let decodeLayerStride = 8

    /// The GPU submissions a decode forward of `layers` decoder layers makes
    /// at `stride` (0: the whole forward at once); the last one also carries
    /// the head.
    public static func decodeSubmissions(layers: Int, stride: Int) -> Int {
        guard stride > 0, layers > 0 else { return 1 }
        return layers / stride + (layers % stride == 0 ? 0 : 1)
    }
}
