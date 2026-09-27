import Foundation
import Darwin
import Metal
import MLX
import Testing

@testable import ProviderCore

@Suite("Native Metal cache retirement", .serialized)
struct NativeMemoryReclamationTests {
    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["DARKBLOOM_NATIVE_RECLAIM_TEST"] == "1"
            && ProcessInfo.processInfo.environment["DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST"] == "1",
        "Requires the isolated native allocation/retirement lane"))
    func releasesCachedMetalResourcesAndPreservesLiveArrays() async throws {
        let mode = ProcessInfo.processInfo.environment["DARKBLOOM_NATIVE_RECLAIM_MODE", default: "scoped"]
        try #require(mode == "direct" || mode == "scoped")
        let gib = try #require(Int(ProcessInfo.processInfo.environment["DARKBLOOM_NATIVE_RECLAIM_GIB", default: "1"]))
        try #require([1, 8, 64].contains(gib))
        try #require((SystemMemory.availableBytes() ?? 0) > (UInt64(gib + 24) << 30),
                     "Bounded diagnostic must leave 24 GiB of actual OS headroom")
        let ticket = WiredMemoryTicket(size: (gib + 2) << 30, policy: WiredSumPolicy(), kind: .active)
        try await ticket.withWiredLimit {
            try measureRetirement(mode, gib: gib)
        }
    }

    @inline(never)
    private func measureRetirement(_ mode: String, gib: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        scopedClearCache()
        let live = arange(1 << 20, dtype: .uint32)
        eval(live)
        Stream.gpu.synchronize()
        let baselineActive = Memory.activeMemory
        let baselineMetal = device.currentAllocatedSize
        allocateScratch(gib: gib)
        Stream.gpu.synchronize()
        let before = Memory.snapshot()
        try #require(before.cacheMemory >= gib << 30, "The test must retire actual declared backing")
        let footprintBefore = footprint()
        if mode == "direct" { Memory.clearCache() }
        else { scopedClearCache() }
        let after = Memory.snapshot()
        let metalAfter = device.currentAllocatedSize
        print("NATIVE_RECLAIM mode=\(mode) gib=\(gib) active_before=\(before.activeMemory) cache_before=\(before.cacheMemory) active_after=\(after.activeMemory) cache_after=\(after.cacheMemory) metal_baseline=\(baselineMetal) metal_after=\(metalAfter) footprint_before=\(footprintBefore) footprint_after=\(footprint())")
        #expect(after.cacheMemory == 0)
        #expect(after.activeMemory <= baselineActive + (1 << 20))
        #expect(metalAfter <= baselineMetal + (16 << 20), "Retired allocations must not be retained by temporary Metal objects")
        #expect(live.asArray(UInt32.self).enumerated().allSatisfy { $0.element == UInt32($0.offset) },
                "Cache retirement must not discard live backing")
        for delay in [10, 100, 500, 1000] {
            Thread.sleep(forTimeInterval: Double(delay) / 1000)
            print("NATIVE_RECLAIM_OBSERVATION mode=\(mode) delay_increment_ms=\(delay) metal_bytes=\(device.currentAllocatedSize) footprint_bytes=\(footprint()) os_available_bytes=\(SystemMemory.availableBytes() ?? 0)")
        }
    }

    @inline(never)
    private func allocateScratch(gib: Int) {
        var arrays: [MLXArray] = []
        for index in 0..<(8 * gib) {
            // Nonuniform data prevents a broadcasted scalar from masquerading
            // as 128 MiB of actually allocated storage.
            let value = arange(128 << 20, dtype: .uint8) + UInt8(truncatingIfNeeded: index + 1)
            eval(value)
            arrays.append(value)
        }
        Stream.gpu.synchronize()
        withExtendedLifetime(arrays) {}
        arrays.removeAll()
    }

    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private func scopedClearCache() {
        autoreleasepool { Memory.clearCache() }
    }
}
