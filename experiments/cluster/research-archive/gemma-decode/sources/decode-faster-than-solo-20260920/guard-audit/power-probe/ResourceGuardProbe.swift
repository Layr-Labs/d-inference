import Darwin
import Foundation
import IOKit.ps

/// Read-only CPU/IOKit comparison. It never admits or launches model work.
private enum ScalarPowerPolicy {
    static func unlimited(_ value: CFTimeInterval) -> Bool {
        value.isFinite && value == kIOPSTimeRemainingUnlimited
    }
}

private struct MemoryObservation: Encodable {
    let actualFreeBytes: UInt64, pressure: Int32, swapBytes: UInt64
}

private struct Environment: Encodable {
    let unlimitedPower: Bool, lowPower: Bool, thermal: Int
    let memory: MemoryObservation
}

private enum ProbeFailure: Error { case arguments, observation, inverse, deadline }

private func legacyPower() -> String? {
    guard let value = IOPSCopyPowerSourcesInfo() else { return nil }
    let info = value.takeRetainedValue()
    return IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
}

private func memory() throws -> MemoryObservation {
    let host = mach_host_self()
    var pageSize: vm_size_t = 0
    var value = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let expected = count
    let pageStatus = host_page_size(host, &pageSize)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(expected)) {
            host_statistics64(host, HOST_VM_INFO64, $0, &count)
        }
    }
    let release = mach_port_deallocate(mach_task_self_, host)
    guard pageStatus == KERN_SUCCESS, status == KERN_SUCCESS, release == KERN_SUCCESS,
          count == expected, pageSize > 0, value.free_count >= value.speculative_count else {
        throw ProbeFailure.observation
    }
    var pressure: Int32 = -1
    var swap = xsw_usage()
    var pressureSize = MemoryLayout<Int32>.size, swapSize = MemoryLayout<xsw_usage>.size
    guard sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0) == 0,
          pressureSize == MemoryLayout<Int32>.size,
          sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0,
          swapSize == MemoryLayout<xsw_usage>.size else { throw ProbeFailure.observation }
    let free = UInt64(value.free_count - value.speculative_count).multipliedReportingOverflow(by: UInt64(pageSize))
    guard !free.overflow else { throw ProbeFailure.observation }
    return .init(actualFreeBytes: free.partialValue, pressure: pressure, swapBytes: swap.xsu_used)
}

private func environment(scalar: Bool) throws -> Environment {
    let ac = scalar ? ScalarPowerPolicy.unlimited(IOPSGetTimeRemainingEstimate()) : legacyPower() == kIOPSACPowerValue
    let thermal = ProcessInfo.processInfo.thermalState.rawValue
    let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    return .init(unlimitedPower: ac, lowPower: lowPower, thermal: thermal, memory: try memory())
}

private struct Timing: Encodable {
    let name: String, samplesNanoseconds: [UInt64]
    let minimum: UInt64, median: UInt64, p95: UInt64, maximum: UInt64
    init(_ name: String, _ samples: [UInt64]) {
        let sorted = samples.sorted()
        self.name = name; samplesNanoseconds = samples
        minimum = sorted[0]; median = sorted[sorted.count / 2]
        p95 = sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        maximum = sorted[sorted.count - 1]
    }
}

@main private enum ResourceGuardProbe {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2, args[0] == "--iterations", let iterations = Int(args[1]),
              (1...4096).contains(iterations) else { throw ProbeFailure.arguments }
        signal(SIGALRM) { _ in _exit(124) }; alarm(10)
        defer { alarm(0) }
        let begin = DispatchTime.now().uptimeNanoseconds
        let cases: [(Double, Bool)] = [(-2, true), (-1, false), (0, false), (1, false),
            (.infinity, false), (-.infinity, false), (.nan, false)]
        guard cases.allSatisfy({ ScalarPowerPolicy.unlimited($0.0) == $0.1 }) else { throw ProbeFailure.inverse }
        var times: [String: [UInt64]] = [:]
        func measured<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = try body()
            times[name, default: []].append(DispatchTime.now().uptimeNanoseconds - start)
            return result
        }
        var stableMismatches = 0, transitions = 0, unavailable = 0
        var lastLegacy: Environment?, lastScalar: Environment?
        for _ in 0..<iterations {
            guard DispatchTime.now().uptimeNanoseconds - begin < 8_000_000_000 else { throw ProbeFailure.deadline }
            try autoreleasepool {
                let before = measured("legacyPowerCopyAndType", legacyPower)
                let scalar = measured("scalarPowerEstimate", IOPSGetTimeRemainingEstimate)
                let after = legacyPower()
                if before == nil || after == nil { unavailable += 1 }
                else if before != after { transitions += 1 }
                else if (before == kIOPSACPowerValue) != ScalarPowerPolicy.unlimited(scalar) { stableMismatches += 1 }
                _ = measured("thermal") { ProcessInfo.processInfo.thermalState.rawValue }
                _ = measured("lowPower") { ProcessInfo.processInfo.isLowPowerModeEnabled }
                _ = try measured("freshMemoryPressureSwap", memory)
                lastLegacy = try measured("legacyCombined") { try environment(scalar: false) }
                lastScalar = try measured("scalarCombined") { try environment(scalar: true) }
            }
        }
        struct Report: Encodable {
            let schema = "fresh_resource_reader_cpu_probe_v1"
            let iterations: Int, stableMismatches: Int, transitions: Int, unavailable: Int
            let scalarInverseCases = 7
            let observationsCachedByProbe = false, nativeOrGPUExecuted = false
            let qualifiesRuntimeAdmission = false
            let timingIncludesMeasurementOverhead = true
            let elapsedNanoseconds: UInt64
            let timings: [Timing]
            let lastLegacy: Environment?, lastScalar: Environment?
        }
        let report = Report(iterations: iterations, stableMismatches: stableMismatches,
            transitions: transitions, unavailable: unavailable,
            elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - begin,
            timings: times.keys.sorted().map { Timing($0, times[$0]!) },
            lastLegacy: lastLegacy, lastScalar: lastScalar)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(report); data.append(0x0a)
        FileHandle.standardOutput.write(data)
        if stableMismatches > 0 || unavailable > 0 { exit(2) }
    }
}
