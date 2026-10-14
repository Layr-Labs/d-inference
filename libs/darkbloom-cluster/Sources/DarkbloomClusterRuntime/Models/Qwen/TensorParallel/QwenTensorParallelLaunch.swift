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

    /// Version of the first exchange; change it whenever `agreement` changes meaning.
    public static let agreementVersion = "darkbloom-tp-launch-v4"

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
}
