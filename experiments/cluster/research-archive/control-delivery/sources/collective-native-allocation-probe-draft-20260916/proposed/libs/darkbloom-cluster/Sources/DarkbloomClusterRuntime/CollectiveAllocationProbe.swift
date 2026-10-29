#if COLLECTIVE_RECORD_ALLOCATION_CHECK
import Foundation
import MLX

@_spi(ClusterTesting) public enum CollectiveAllocationProbe {
    public static func cases() throws -> Data {
        struct Value: Encodable { let id: String; let byteCounts: [Int]; let primingByteCounts: [Int]; let rounds: Int; let failure: String }
        return try JSONEncoder().encode(CollectiveAllocationCase.all.map {
            Value(id: $0.id, byteCounts: $0.geometries.map(\.bytes), primingByteCounts: $0.priming.map(\.bytes), rounds: $0.rounds, failure: $0.failure.rawValue)
        })
    }

    public static func run(caseID: String) throws -> Data {
        let test = try CollectiveAllocationCase.find(caseID)
        return try MLX.withError { native in
            try QwenResidentResourceEnvironment.require()
            Memory.cacheLimit = 0
            Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache(); try native.check()
            let baselineNative = Memory.snapshot(), baselinePhysical = try CollectiveAllocationFootprint.read()
            Memory.peakMemory = 0
            let start = DispatchTime.now().uptimeNanoseconds
            var nextResourceCheck: UInt64 = 0
            func check() throws {
                try native.check()
                let now = DispatchTime.now().uptimeNanoseconds
                guard now >= start, now - start < 55_000_000_000,
                      Memory.activeMemory <= baselineNative.activeMemory + 256 * 1024 * 1024 else {
                    throw ProbeError("Allocation fixture exceeds fixed native/time bound")
                }
                if now >= nextResourceCheck {
                    try QwenResidentResourceEnvironment.require()
                    let physical = try CollectiveAllocationFootprint.read()
                    guard physical.lifetimeMaximumBytes <= baselinePhysical.currentBytes + 512 * 1024 * 1024 else {
                        throw ProbeError("Allocation fixture exceeds fixed process high-water bound")
                    }
                    nextResourceCheck = now + 100_000_000
                }
                try native.check()
            }
            do {
                let result = try autoreleasepool { try CollectiveAllocationExecution.run(test, check: check) }
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try native.check(); try check()
                let beforeCleanup = Memory.snapshot()
                Memory.clearCache(); try native.check()
                let finalNative = Memory.snapshot(), finalPhysical = try CollectiveAllocationFootprint.read()
                guard result.weakArrays.allSatisfy({ $0.value == nil }),
                      finalNative.activeMemory == baselineNative.activeMemory, finalNative.cacheMemory == 0,
                      finalPhysical.lifetimeMaximumBytes >= baselinePhysical.lifetimeMaximumBytes else {
                    throw ProbeError("Allocation fixture retained native arrays or lost high-water evidence")
                }
                let report = try CollectiveAllocationReport(test: test, result: result, baselineNative: baselineNative,
                    beforeCleanup: beforeCleanup, finalNative: finalNative, baselinePhysical: baselinePhysical,
                    finalPhysical: finalPhysical, elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - start,
                    hardware: try CollectiveAllocationFootprint.systemString("hw.model"),
                    osBuild: try CollectiveAllocationFootprint.systemString("kern.osversion"))
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(report)
                guard data.count <= 65_536 else { throw ProbeError("Allocation fixture report exceeds bound") }
                return data
            } catch {
                let primary = error
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache(); try native.check()
                throw primary
            }
        }
    }
}
#endif
