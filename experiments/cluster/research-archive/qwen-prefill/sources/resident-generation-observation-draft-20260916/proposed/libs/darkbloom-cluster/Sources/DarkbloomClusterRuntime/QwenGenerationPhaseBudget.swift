import Foundation

/// Named host allocations only, not a whole-process peak bound. The future
/// native owner must supply an actual host-allocation bound and reserve this
/// increment through trace encoding/publication. No such native entry exists
/// in this first slice; it must not borrow the unmodified request allowance.
struct QwenGenerationPhaseBudget: Encodable, Equatable {
    static let maximumEncodedBytes = 256 * 1024
    let maximumEvents: Int
    let eventLogicalBytes: Int
    let eventAllocationBytes: Int
    let encodedResultAllocationBytes: Int
    let encodingScratchAllowanceBytes: Int
    let metadataAllowanceBytes: Int
    let requiredHostReservationBytes: Int

    static func derive(identity: QwenGenerationPhaseIdentity,
                       hostAllocationBound: (Int) throws -> Int) throws -> Self {
        try identity.validate()
        let frames = (identity.promptCount - 1) / identity.chunkSize + 1
        // At most 12 frame events per rank today; 16 leaves explicit bounded
        // room for source-compatible scalar markers, plus 32 request markers.
        let count = frames.multipliedReportingOverflow(by: 16)
        guard !count.overflow, count.partialValue <= 480 else {
            throw QwenGenerationPhaseError("Observed request exceeds the 512-event allowance")
        }
        let events = count.partialValue + 32
        let logical = events.multipliedReportingOverflow(by: MemoryLayout<QwenGenerationPhaseEvent>.stride)
        guard !logical.overflow, logical.partialValue > 0 else {
            throw QwenGenerationPhaseError("Observation event byte count overflow")
        }
        func rounded(_ bytes: Int) throws -> Int {
            let value = try hostAllocationBound(bytes)
            guard value >= bytes, value <= 4 * 1024 * 1024 else {
                throw QwenGenerationPhaseError("Invalid actual observation host-allocation bound")
            }
            return value
        }
        let eventBytes = try rounded(logical.partialValue)
        let outputBytes = try rounded(maximumEncodedBytes)
        let scratchBytes = try rounded(2 * maximumEncodedBytes)
        let metadataBytes = try rounded(16 * 1024)
        var total = 0
        for value in [eventBytes, outputBytes, scratchBytes, metadataBytes] {
            let sum = total.addingReportingOverflow(value)
            guard !sum.overflow, sum.partialValue <= 8 * 1024 * 1024 else {
                throw QwenGenerationPhaseError("Observation host reservation exceeds its closed bound")
            }
            total = sum.partialValue
        }
        return .init(maximumEvents: events, eventLogicalBytes: logical.partialValue,
            eventAllocationBytes: eventBytes, encodedResultAllocationBytes: outputBytes,
            encodingScratchAllowanceBytes: scratchBytes, metadataAllowanceBytes: metadataBytes,
            requiredHostReservationBytes: total)
    }
}
