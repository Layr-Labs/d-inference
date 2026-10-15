import Foundation

func memorySample(_ point: QwenResidentMemoryPoint, at stamp: UInt64,
                  reads: Int? = nil, total: Int? = nil, free: Int = 8 * 1_073_741_824,
                  wide: Bool = false) -> QwenResidentMemorySample {
    let n = wide ? Int.max : 1
    return .init(point: point, startedNanoseconds: stamp, completedNanoseconds: stamp + (wide ? 0 : 3),
        osStartedNanoseconds: stamp + (wide ? 0 : 1), osCompletedNanoseconds: stamp + (wide ? 0 : 2),
        physicalMemoryBytes: wide ? n : 24 * 1_073_741_824, pageSizeBytes: wide ? n : 16384,
        kernelFreePages: wide ? n : 524_288, freePages: wide ? n : 524_288,
        inactivePages: n, speculativePages: wide ? n : 0,
        actualFreeBytes: wide ? n : free, estimatedReclaimableBytes: wide ? n : free + 16384,
        pressureLevel: wide ? n : 1, swapUsedBytes: wide ? n : 0,
        pages: .init(active: n, wired: n, purgeable: n, fileBacked: n, anonymous: n, compressor: n),
        activeBytes: n, cacheBytes: wide ? n : 0, peakBytes: n,
        allocatorLimitBytes: wide ? n : 12 * 1_073_741_824,
        requiredActualFreeBytes: wide ? n : 6 * 1_073_741_824,
        requiredAllocatorBytes: wide ? n : 2 * 1_073_741_824, authorizedTensorCount: reads, selectedTensorCount: total)
}

/// Serialization-only maximum-width envelope, deliberately not an admissible
/// memory trace. Actual runtime/reader semantics are tested separately.
func wideMemoryTrace() -> QwenResidentMemoryTrace {
    .init(readyUptimeNanoseconds: UInt64.max,
        samples: (0..<QwenResidentMemoryRecorder.maximumSamples).map { _ in
            memorySample(.loadedRequestGuard, at: UInt64.max, reads: Int.max, total: Int.max, wide: true)
        })
}

func memoryRecorder() throws -> QwenResidentMemoryRecorder {
    let id = identity(prompt: 8192, chunk: 256, output: 128)
    let budget = try QwenGenerationPhaseBudget.derive(identity: id,
        hostAllocationBound: QwenGenerationPhaseHostAllocation.bound)
    return try .init(rank: id.rank, plan: id.planFingerprint, build: id.buildSHA256, budget: budget)
}

func memoryReady(_ recorder: QwenResidentMemoryRecorder) throws {
    try recorder.append(memorySample(.load, at: 1, reads: 0, total: 10))
    try recorder.append(memorySample(.loadComplete, at: 1_000_000_001, reads: 10, total: 10))
    try recorder.append(memorySample(.loadedRequestGuard, at: 1_000_000_011))
    try recorder.markReady(now: 1_000_000_020)
}
