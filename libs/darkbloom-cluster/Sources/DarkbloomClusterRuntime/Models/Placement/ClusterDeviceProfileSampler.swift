import Darwin
import DarkbloomClusterPlacement
import Foundation
import IOKit
import IOKit.ps
import MLX

/// Reads this Mac's device profile. Everything is asked of the system at the
/// moment of the call: `sysctl`, the Metal device and, for memory, the host
/// memory gate's own sampler and policy. Nothing is looked up by machine and
/// nothing identifies the machine. No model is loaded and no GPU work is done.
public enum ClusterDeviceProfileSampler {
    public static func sample() throws -> ClusterDeviceProfile {
        let os = try QwenDenseStageLoadResources.observeOS()
        let memory = ClusterDeviceMemory.gate(os, now: DispatchTime.now().uptimeNanoseconds)
        let gpu = GPU.deviceInfo()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return try .init(chip: text("machdep.cpu.brand_string") ?? "unknown",
            performanceCores: integer("hw.perflevel0.physicalcpu") ?? ProcessInfo.processInfo.processorCount,
            efficiencyCores: integer("hw.perflevel1.physicalcpu") ?? 0, gpuCores: gpuCoreCount(),
            osVersion: "\(version.majorVersion).\(version.minorVersion)"
                + (version.patchVersion > 0 ? ".\(version.patchVersion)" : ""),
            osBuild: text("kern.osversion") ?? "unknown", physicalMemoryBytes: memory.physicalMemoryBytes,
            gpuRecommendedWorkingSetBytes: Int(min(gpu.maxRecommendedWorkingSetSize, UInt64(Int.max))),
            gpuMaximumBufferBytes: gpu.maxBufferSize,
            // The limit the load gate compares with, in a process that has not changed it.
            allocatorLimitBytes: Memory.memoryLimit, memory: memory, power: power())
    }

    static func text(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, (2...256).contains(size) else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        let value = String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let printable = String(value.unicodeScalars.filter { $0.value >= 32 && $0.value < 127 }.prefix(96))
        return printable.isEmpty ? nil : printable
    }

    static func integer(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size, value >= 0 else { return nil }
        return Int(value)
    }

    /// The accelerator's `gpu-core-count`, when the registry publishes one.
    static func gpuCoreCount() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var result: Int?
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            if let property = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0),
               let number = property.takeRetainedValue() as? NSNumber, (1...4096).contains(number.intValue) {
                result = max(result ?? 0, number.intValue)
            }
        }
        return result
    }

    /// The same three readings `QwenResidentResourceEnvironment.require` refuses on.
    static func power() -> ClusterDevicePower {
        var external = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            external = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPSACPowerValue
        }
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        default: thermal = "critical"
        }
        return .init(onExternalPower: external, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, thermalState: thermal)
    }
}
