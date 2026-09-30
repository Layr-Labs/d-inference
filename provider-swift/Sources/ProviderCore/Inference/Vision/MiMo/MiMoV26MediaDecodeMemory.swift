import MLXVLM

/// Encoded owners and all decoded results stay live; decoder scratch is reused
/// sequentially. The SDK drains each image/frame's autorelease pool before the
/// next decode. Audio keeps its existing conservative full working-byte charge.
struct MiMoV26MediaDecodeMemory {
    private(set) var retainedBytes: UInt64
    private(set) var transientBytes: UInt64 = 0

    init(hostBytes: UInt64) { retainedBytes = hostBytes }

    var peakBytes: UInt64 {
        get throws {
            let (total, overflow) = retainedBytes.addingReportingOverflow(transientBytes)
            guard !overflow else { throw MiMoV26MultimodalError.reservationRejected }
            return total
        }
    }

    mutating func includeRetained(_ bytes: UInt64) throws {
        let (total, overflow) = retainedBytes.addingReportingOverflow(bytes)
        guard !overflow else { throw MiMoV26MultimodalError.reservationRejected }
        retainedBytes = total
    }

    mutating func includeVisual(_ memory: MiMoV26VisualDecodeMemory) throws {
        guard let retained = UInt64(exactly: memory.retainedBytes),
            let transient = UInt64(exactly: memory.transientBytes)
        else { throw MiMoV26MultimodalError.reservationRejected }
        try includeRetained(retained)
        transientBytes = max(transientBytes, transient)
    }
}
