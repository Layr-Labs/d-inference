import Foundation

extension ClusterDeviceProfile {
    /// TEST ONLY: this profile as the planner would see it on a Mac that can
    /// give a model at most `admissibleBytes`, so that a bench pair of large
    /// Macs is planned the way a pair of smaller Macs would be (a real split
    /// instead of one Mac holding the whole model).
    ///
    /// It only ever lowers: every figure the planner compares a requirement
    /// with (free pages, counted and droppable file cache, what closing
    /// applications or a restart would give, the GPU's working set, the wired
    /// limit and the allocator's limit) is clamped to the cap, so a range
    /// beyond it answers `.never`. Physical memory, the chip, the gate's
    /// constants and the speed index stay as observed. A Mac that already has
    /// less than the cap is returned unchanged.
    ///
    /// It is an input to the planner and nothing else. The load gate on each
    /// Mac never sees it and decides every load on that Mac's own memory, so a
    /// cap can make the planner more cautious but never admit a load.
    public func cappedForBench(admissibleBytes cap: Int) throws -> ClusterDeviceProfile {
        guard cap >= memory.minimumAdmissibleBytes, cap > 0 else {
            throw ClusterPlacementError("A bench cap of \(cap) bytes is below the load gate's minimum of \(memory.minimumAdmissibleBytes) bytes")
        }
        let m = memory
        let free = min(m.actualFreeBytes, cap)
        let counted = min(m.countedFileCacheBytes, cap - free)
        let above = min(m.fileCacheAboveReserveBytes, cap - free)
        let pageable = min(m.pageableBytes, cap)
        let compressor = max(0, min(m.compressorBytes, cap - pageable))
        let lowered = ClusterDeviceMemory(gatePolicy: m.gatePolicy, sampledUTC: m.sampledUTC, judged: m.judged,
            unjudgedReason: m.unjudgedReason, physicalMemoryBytes: m.physicalMemoryBytes, actualFreeBytes: free,
            countedFileCacheBytes: counted, admissibleNowBytes: free + counted, fileBackedBytes: m.fileBackedBytes,
            fileCacheReserveBytes: m.fileCacheReserveBytes, fileCacheAboveReserveBytes: above,
            anonymousBytes: m.anonymousBytes, wiredBytes: m.wiredBytes, compressorBytes: compressor,
            pageableBytes: pageable, pressureLevel: m.pressureLevel, swapUsedBytes: m.swapUsedBytes,
            minimumAdmissibleBytes: m.minimumAdmissibleBytes, minimumTrulyFreeBytes: m.minimumTrulyFreeBytes,
            loadingHeadroomBytes: m.loadingHeadroomBytes, allocatorHeadroomBytes: m.allocatorHeadroomBytes,
            loadScratchBytes: m.loadScratchBytes, pageSizeBytes: m.pageSizeBytes)
        var value = try ClusterDeviceProfile(chip: chip, performanceCores: performanceCores, efficiencyCores: efficiencyCores,
            gpuCores: gpuCores, osVersion: osVersion, osBuild: osBuild, physicalMemoryBytes: physicalMemoryBytes,
            gpuRecommendedWorkingSetBytes: min(gpuRecommendedWorkingSetBytes, cap), gpuMaximumBufferBytes: gpuMaximumBufferBytes,
            allocatorLimitBytes: min(allocatorLimitBytes, cap), memory: lowered, power: power,
            wiredLimitBytes: wiredLimitBytes.map { min($0, cap) })
        value.speedIndex = speedIndex
        try value.validate()
        return value
    }
}
