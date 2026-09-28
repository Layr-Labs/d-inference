import Foundation

/// Operational IO accounting, separate from tensor/model storage identity.
struct CheckpointAlignedReadAccounting: Codable, Equatable {
    let schema: String
    let alignmentBytes: Int
    let maximumScratchAllocationBytes: Int
    let cacheBypassRequested: Bool
    let readAheadDisabledRequested: Bool
    let fileCacheAbsenceEstablished: Bool
    private(set) var selectedBytes: Int
    private(set) var requestedReadBytes: Int
    private(set) var returnedReadBytes: Int
    private(set) var paddingReadBytes: Int
    private(set) var preadCalls: Int
    private(set) var interruptedCalls: Int
    private(set) var shortEOFReads: Int
    private(set) var largestScratchRequestBytes: Int
    private(set) var largestScratchAllocationBytes: Int

    init() {
        schema = "checkpoint_aligned_selected_read_v1"
        alignmentBytes = CheckpointAlignedReadPlan.alignmentBytes
        maximumScratchAllocationBytes = CheckpointAlignedReadPlan.maximumScratchAllocationBytes
        cacheBypassRequested = true; readAheadDisabledRequested = true
        fileCacheAbsenceEstablished = false
        selectedBytes = 0; requestedReadBytes = 0; returnedReadBytes = 0; paddingReadBytes = 0
        preadCalls = 0; interruptedCalls = 0; shortEOFReads = 0
        largestScratchRequestBytes = 0; largestScratchAllocationBytes = 0
    }

    mutating func recordCall(requested: Int, returned: Int, interrupted: Bool, shortEOF: Bool) throws {
        requestedReadBytes = try Self.add(requestedReadBytes, requested)
        returnedReadBytes = try Self.add(returnedReadBytes, returned)
        preadCalls = try Self.add(preadCalls, 1)
        interruptedCalls = try Self.add(interruptedCalls, interrupted ? 1 : 0)
        shortEOFReads = try Self.add(shortEOFReads, shortEOF ? 1 : 0)
    }
    mutating func finish(selected: Int, scratchRequested: Int, scratchAllocated: Int) throws {
        guard selected >= 0, returnedReadBytes >= selected,
              scratchRequested <= scratchAllocated, scratchAllocated <= maximumScratchAllocationBytes else {
            throw ProbeError("Aligned checkpoint read accounting differs")
        }
        selectedBytes = selected; paddingReadBytes = returnedReadBytes - selected
        largestScratchRequestBytes = scratchRequested; largestScratchAllocationBytes = scratchAllocated
    }
    mutating func merge(_ other: Self) throws {
        guard schema == other.schema, alignmentBytes == other.alignmentBytes,
              maximumScratchAllocationBytes == other.maximumScratchAllocationBytes,
              other.cacheBypassRequested, other.readAheadDisabledRequested, !other.fileCacheAbsenceEstablished else {
            throw ProbeError("Aligned checkpoint read policy differs")
        }
        selectedBytes = try Self.add(selectedBytes, other.selectedBytes)
        requestedReadBytes = try Self.add(requestedReadBytes, other.requestedReadBytes)
        returnedReadBytes = try Self.add(returnedReadBytes, other.returnedReadBytes)
        paddingReadBytes = try Self.add(paddingReadBytes, other.paddingReadBytes)
        preadCalls = try Self.add(preadCalls, other.preadCalls)
        interruptedCalls = try Self.add(interruptedCalls, other.interruptedCalls)
        shortEOFReads = try Self.add(shortEOFReads, other.shortEOFReads)
        largestScratchRequestBytes = max(largestScratchRequestBytes, other.largestScratchRequestBytes)
        largestScratchAllocationBytes = max(largestScratchAllocationBytes, other.largestScratchAllocationBytes)
    }
    private static func add(_ a: Int, _ b: Int) throws -> Int {
        let value = a.addingReportingOverflow(b)
        guard a >= 0, b >= 0, !value.overflow else { throw ProbeError("Aligned read counter overflow") }
        return value.partialValue
    }
}

/// Rounded IO windows only. Selected bytes are still copied exactly once into
/// the existing Data destination; this is not tensor or MLX allocation metadata.
struct CheckpointAlignedReadPlan {
    static let alignmentBytes = 16_384
    static let maximumScratchRequestBytes = 8 * 1024 * 1024
    // Conservative operational host allowance: one bounded anonymous scratch
    // extent plus one alignment page. Mapped bytes are reported separately.
    static let maximumScratchAllocationBytes = maximumScratchRequestBytes + alignmentBytes
    let selectedStart: Int, selectedEnd: Int, alignedStart: Int, alignedEnd: Int, scratchBytes: Int

    init(fileSize: Int, offset: Int, count: Int) throws {
        guard fileSize >= 0, offset >= 0, offset <= fileSize, count > 0, count <= fileSize - offset else {
            throw ProbeError("Aligned checkpoint selected range is out of range")
        }
        selectedStart = offset; selectedEnd = offset + count
        let a = Self.alignmentBytes
        alignedStart = offset - offset % a
        let remainder = selectedEnd % a, padding = remainder == 0 ? 0 : a - remainder
        let end = selectedEnd.addingReportingOverflow(padding)
        guard !end.overflow else { throw ProbeError("Aligned checkpoint rounded range overflow") }
        alignedEnd = end.partialValue
        scratchBytes = min(Self.maximumScratchRequestBytes, alignedEnd - alignedStart)
    }
}
