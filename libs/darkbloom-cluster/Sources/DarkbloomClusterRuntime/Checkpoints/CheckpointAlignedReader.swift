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

    /// `count` runs of `length` bytes, `stride` apart from `offset`, copied back to back into `destination`: one
    /// rank's part of every row of a tensor divided on an inner axis. Runs less than an alignment page apart share
    /// pages, so they are read together, as many as one scratch request holds, instead of one aligned read each.
    /// MiMo's expert `down_proj` is about a million 512-byte runs per tensor; one aligned uncached read each (about
    /// 47 µs on an M5 Ultra) kept its tensor-parallel load past an hour against a startup deadline of about ten
    /// minutes. Runs farther apart are read one at a time, as `read` reads them.
    static func read(descriptor: Int32, fileSize: Int, into destination: UnsafeMutableRawBufferPointer,
        offset: Int, length: Int, stride: Int, count: Int, checkUnchanged: () throws -> Void,
        readCall: Read = { Darwin.pread($0, $1, $2, $3) }
    ) throws -> CheckpointAlignedReadAccounting {
        let a = CheckpointAlignedReadPlan.alignmentBytes, page = Int(getpagesize())
        let total = length.multipliedReportingOverflow(by: count)
        let span = stride.multipliedReportingOverflow(by: max(0, count - 1))
        guard descriptor >= 0, page == a, destination.baseAddress != nil, length > 0, count > 0, stride >= length,
              offset >= 0, !total.overflow, total.partialValue == destination.count, !span.overflow,
              span.partialValue <= fileSize - offset - length else {
            throw ProbeError("Aligned checkpoint runs are out of range")
        }
        let perWindow = stride - length < a ? (CheckpointAlignedReadPlan.maximumScratchRequestBytes - 2 * a) / stride : 0
        guard perWindow >= 2, count >= 2 else {
            var statistics: CheckpointAlignedReadAccounting?
            for run in 0..<count {
                let target = UnsafeMutableRawBufferPointer(start: destination.baseAddress!.advanced(by: run * length), count: length)
                let part = try read(descriptor: descriptor, fileSize: fileSize, into: target, offset: offset + run * stride,
                                    checkUnchanged: checkUnchanged, readCall: readCall)
                if statistics == nil { statistics = part } else { try statistics!.merge(part) }
            }
            return statistics!
        }
        // A window of `perWindow` runs spans at most `perWindow * stride` bytes, and its aligned extent at most two
        // pages more: within one scratch request.
        let windowBytes = min(perWindow, count) * stride
        let scratchBytes = (windowBytes + a - 1) / a * a + 2 * a
        try checkUnchanged()
        let allocation = mmap(nil, scratchBytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        guard allocation != MAP_FAILED, let scratch = allocation else {
            throw ProbeError("Cannot allocate aligned checkpoint scratch")
        }
        var mapped = true
        defer { if mapped { _ = munmap(scratch, scratchBytes) } }
        guard UInt(bitPattern: scratch) % UInt(a) == 0,
              scratchBytes <= CheckpointAlignedReadPlan.maximumScratchRequestBytes else {
            throw ProbeError("Aligned checkpoint scratch exceeded its host allocation allowance: requested=\(scratchBytes)")
        }
        var statistics = CheckpointAlignedReadAccounting(), written = 0, largest = 0, run = 0
        while run < count {
            let runs = min(perWindow, count - run)
            let selectedStart = offset + run * stride, selectedEnd = selectedStart + (runs - 1) * stride + length
            let alignedStart = selectedStart - selectedStart % a, alignedEnd = (selectedEnd + a - 1) / a * a
            let requested = alignedEnd - alignedStart, expected = min(requested, fileSize - alignedStart)
            guard requested <= scratchBytes else { throw ProbeError("Aligned checkpoint run window exceeds its scratch") }
            while true {
                try checkUnchanged()
                let returned = readCall(descriptor, scratch, requested, off_t(alignedStart))
                if returned < 0 && errno == EINTR {
                    try statistics.recordCall(requested: requested, returned: 0, interrupted: true, shortEOF: false)
                    continue // retry the SAME aligned pointer, offset and length
                }
                guard returned > 0, returned == expected else { throw ProbeError("Short or failed aligned checkpoint read") }
                try statistics.recordCall(requested: requested, returned: returned, interrupted: false, shortEOF: returned < requested)
                break
            }
            try checkUnchanged()
            for index in 0..<runs {
                destination.baseAddress!.advanced(by: written).copyMemory(
                    from: scratch.advanced(by: selectedStart + index * stride - alignedStart), byteCount: length)
                written += length
            }
            largest = max(largest, requested); run += runs
        }
        try checkUnchanged()
        guard written == destination.count else { throw ProbeError("Aligned checkpoint selected byte count differs") }
        try statistics.finish(selected: written, scratchRequested: largest, scratchAllocated: scratchBytes)
        guard munmap(scratch, scratchBytes) == 0 else { throw ProbeError("Cannot release aligned checkpoint scratch") }
        mapped = false
        return statistics
    }
}
