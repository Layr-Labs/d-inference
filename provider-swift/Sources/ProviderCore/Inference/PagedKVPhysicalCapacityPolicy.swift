// Copyright © 2026 Eigen Labs.
//
// Physical-capacity policy for the experimental paged KV backend.
//
// A slot's logical unified-memory grant is an admission ceiling, not an
// instruction to preallocate that many bytes. Paged slabs are physically
// materialized at engine construction, so their budget is independently
// bounded by useful concurrent context, live OS/MLX headroom, machine size,
// and Metal's per-buffer limit.

import Foundation
import MLXLMCommon

enum PagedKVPhysicalCapacityPolicy {
    static let gib = 1 << 30
    static let mib = 1 << 20

    /// Beyond 32K tokens per running row, reserving eager physical pages has
    /// sharply diminishing value. Longer requests remain admissible only
    /// when the finite pool can reserve them; otherwise they retry on a
    /// contiguous provider.
    static let usefulContextTokensPerRequest = 32_768
    /// A paged slot may eagerly own at most 1/16 of physical RAM.
    static let physicalMemoryDivisor = 16
    /// Never eagerly materialize more than 8 GiB for one model.
    static let absoluteHardCapBytes = 8 * gib
    /// Use at most one quarter of currently safe live KV headroom. The
    /// remainder absorbs co-resident loads, non-MLX processes, and sampling
    /// drift between the preflight and Metal allocation.
    static let liveHeadroomDivisor = 4
    /// Production grants must still leave a useful pool; otherwise explicit
    /// paged selection degrades to contiguous before allocation.
    static let minimumProductionPoolBytes = 1 * gib

    struct Inputs: Sendable, Equatable {
        let physicalMemoryBytes: UInt64
        let liveKVHeadroomBytes: UInt64
        let maxBufferLength: Int
    }

    struct Plan: Sendable, Equatable {
        let capacityBytes: Int
        let usefulDemandBytes: UInt64
        let liveAllocationLimitBytes: UInt64
        let machineHardCapBytes: UInt64
    }

    enum Decision: Sendable, Equatable {
        case paged(Plan)
        case contiguous(reason: String)
    }

    static func fp16BytesPerToken(layerKinds: [CBv2LayerKind]) -> Int? {
        var total = 0
        for kind in layerKinds where kind.sharesKVWithLayer == nil {
            guard kind.kvHeads > 0, kind.headDim > 0 else { return nil }
            var layer = 2
            for factor in [kind.kvHeads, kind.headDim, MemoryLayout<Float16>.size] {
                let (next, overflow) = layer.multipliedReportingOverflow(by: factor)
                guard !overflow else { return nil }
                layer = next
            }
            let (nextTotal, overflow) = total.addingReportingOverflow(layer)
            guard !overflow else { return nil }
            total = nextTotal
        }
        return total > 0 ? total : nil
    }

    static func decide(
        logicalGrantBytes: Int,
        fp16BytesPerToken: Int,
        maxContextLength: Int?,
        maxConcurrentRequests: Int,
        inputs: Inputs
    ) -> Decision {
        guard logicalGrantBytes > 0 else {
            return .contiguous(reason: "physical_capacity: zero logical grant")
        }
        guard fp16BytesPerToken > 0 else {
            return .contiguous(reason: "physical_capacity: unknown KV byte rate")
        }
        guard maxConcurrentRequests > 0 else {
            return .contiguous(reason: "physical_capacity: invalid concurrency")
        }
        guard inputs.maxBufferLength > 0 else {
            return .contiguous(reason: "physical_capacity: Metal maxBufferLength unavailable")
        }

        let context = UInt64(max(
            1,
            min(
                maxContextLength ?? usefulContextTokensPerRequest,
                usefulContextTokensPerRequest)))
        let usefulTokens = saturatingMultiply(context, UInt64(maxConcurrentRequests))
        let usefulDemand = saturatingMultiply(
            usefulTokens, UInt64(fp16BytesPerToken))
        let machineCap = min(
            UInt64(absoluteHardCapBytes),
            inputs.physicalMemoryBytes / UInt64(physicalMemoryDivisor))
        let liveLimit = inputs.liveKVHeadroomBytes / UInt64(liveHeadroomDivisor)
        let twoBufferLimit = saturatingMultiply(
            UInt64(inputs.maxBufferLength), 2)
        let planned = min(
            UInt64(logicalGrantBytes),
            usefulDemand,
            machineCap,
            liveLimit,
            twoBufferLimit,
            UInt64(Int.max))
        let rounded = planned / UInt64(mib) * UInt64(mib)

        // Tiny-model unit/benchmark builds intentionally use sub-GiB logical
        // grants. Production re-slicing already enforces a ≥1 GiB grant, so
        // apply the serving floor exactly where it is meaningful.
        let minimum = logicalGrantBytes >= minimumProductionPoolBytes
            ? UInt64(minimumProductionPoolBytes)
            : UInt64(mib)
        guard rounded >= minimum else {
            return .contiguous(
                reason: "physical_capacity: safe pool \(rounded) B is below "
                    + "the \(minimum) B serviceability floor")
        }

        return .paged(
            Plan(
                capacityBytes: Int(rounded),
                usefulDemandBytes: usefulDemand,
                liveAllocationLimitBytes: liveLimit,
                machineHardCapBytes: machineCap))
    }

    private static func saturatingMultiply(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? .max : product
    }
}
