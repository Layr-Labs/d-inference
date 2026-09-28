import Darwin
import Foundation

enum CheckpointAlignedReader {
    typealias Read = (Int32, UnsafeMutableRawPointer, Int, off_t) -> Int

    /// Uses the already verified descriptor. The caller opted this descriptor
    /// into F_NOCACHE/F_RDAHEAD; no payload file is opened, mapped, or retained.
    /// Scratch is released before SafeTensorReader constructs the MLX copy.
    static func read(descriptor: Int32, fileSize: Int, into destination: UnsafeMutableRawBufferPointer,
        offset: Int, checkUnchanged: () throws -> Void,
        readCall: Read = { Darwin.pread($0, $1, $2, $3) }
    ) throws -> CheckpointAlignedReadAccounting {
        let plan = try CheckpointAlignedReadPlan(fileSize: fileSize, offset: offset, count: destination.count)
        let a = CheckpointAlignedReadPlan.alignmentBytes, page = Int(getpagesize())
        guard descriptor >= 0, page == a, destination.baseAddress != nil else {
            throw ProbeError("Aligned checkpoint descriptor, page size or destination is invalid")
        }
        try checkUnchanged()
        // Anonymous private pages only (fd=-1), never a mapping of the verified
        // file. The exact page-multiple extent avoids malloc bucket assumptions.
        let allocation = mmap(nil, plan.scratchBytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        guard allocation != MAP_FAILED, let scratch = allocation else {
            throw ProbeError("Cannot allocate aligned checkpoint scratch")
        }
        var mapped = true
        defer { if mapped { _ = munmap(scratch, plan.scratchBytes) } }
        let allocated = plan.scratchBytes
        guard UInt(bitPattern: scratch) % UInt(a) == 0,
              allocated >= plan.scratchBytes,
              allocated <= plan.scratchBytes + a,
              allocated <= CheckpointAlignedReadPlan.maximumScratchAllocationBytes else {
            throw ProbeError("Aligned checkpoint scratch exceeded its host allocation allowance: requested=\(plan.scratchBytes) allocated=\(allocated) alignmentRemainder=\(UInt(bitPattern: scratch) % UInt(a))")
        }
        var statistics = CheckpointAlignedReadAccounting(), current = plan.alignedStart, written = 0
        while current < plan.alignedEnd {
            let requested = min(plan.scratchBytes, plan.alignedEnd - current)
            let expected = min(requested, fileSize - current)
            try checkUnchanged()
            let count = readCall(descriptor, scratch, requested, off_t(current))
            if count < 0 && errno == EINTR {
                try statistics.recordCall(requested: requested, returned: 0, interrupted: true, shortEOF: false)
                continue // retry the SAME aligned pointer, offset and length
            }
            guard count > 0, count == expected else {
                throw ProbeError("Short or failed aligned checkpoint read")
            }
            try statistics.recordCall(requested: requested, returned: count,
                interrupted: false, shortEOF: count < requested)
            try checkUnchanged()
            let lower = max(current, plan.selectedStart), upper = min(current + count, plan.selectedEnd)
            guard lower < upper, lower == plan.selectedStart + written else {
                throw ProbeError("Aligned checkpoint selected copy lost its contiguous frontier")
            }
            let selected = upper - lower
            destination.baseAddress!.advanced(by: written).copyMemory(
                from: scratch.advanced(by: lower - current), byteCount: selected)
            written += selected; current += requested
        }
        try checkUnchanged()
        guard written == destination.count else { throw ProbeError("Aligned checkpoint selected byte count differs") }
        try statistics.finish(selected: written, scratchRequested: plan.scratchBytes, scratchAllocated: allocated)
        guard munmap(scratch, plan.scratchBytes) == 0 else { throw ProbeError("Cannot release aligned checkpoint scratch") }
        mapped = false
        return statistics
    }
}
