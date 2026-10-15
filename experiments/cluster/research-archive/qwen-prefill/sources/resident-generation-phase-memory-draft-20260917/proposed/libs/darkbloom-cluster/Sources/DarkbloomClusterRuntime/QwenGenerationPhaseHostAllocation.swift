import Darwin
import Foundation

enum QwenGenerationPhaseHostAllocation {
    /// Explicit host allocation rounding, separate from native MLX buffers.
    /// One page also covers the small collection/header rounding; the recorder
    /// checks its actual reserved element capacity before accepting this bound.
    static func bound(_ bytes: Int) throws -> Int {
        guard bytes > 0, bytes <= 2 * 1024 * 1024 else { throw ProbeError("Phase host allocation input exceeds bound") }
        let padded = bytes.addingReportingOverflow(4096)
        guard !padded.overflow else { throw ProbeError("Phase host allocation overflow") }
        let value = malloc_good_size(padded.partialValue)
        guard value >= padded.partialValue, value <= 4 * 1024 * 1024 else {
            throw ProbeError("Phase host allocator rounding exceeds bound")
        }
        return value
    }

}
