import Foundation

/// Named host allocations only, not a whole-process peak bound. The native
/// resource owner supplies actual host rounding and reserves this increment
/// through trace encoding/publication, separately from request native arrays.
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
        return try derive(promptCount: identity.promptCount, chunkSize: identity.chunkSize,
            hostAllocationBound: hostAllocationBound)
    }

    static func derive(promptCount: Int, chunkSize: Int,
                       hostAllocationBound: (Int) throws -> Int) throws -> Self {
        guard (1...8192).contains(promptCount), (1...512).contains(chunkSize) else {
            throw QwenGenerationPhaseError("Invalid observation allowance geometry")
        }
        let frames = (promptCount - 1) / chunkSize + 1
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
