import Foundation
import Darwin

extension HardwareInfo: CustomStringConvertible {
    public var description: String {
        """
        Hardware Info:
          Machine:    \(machineModel)
          Chip:       \(chipName)
          Family:     \(chipFamily.rawValue) \(chipTier.rawValue)
          Memory:     \(memoryGb) GB total
          Available:  \(memoryAvailableGb) GB (for inference)
          CPU:        \(cpuCores.total) cores (\(cpuCores.performance) P + \(cpuCores.efficiency) E)
          GPU:        \(gpuCores) cores
          Bandwidth:  \(memoryBandwidthGbs) GB/s
        """
    }
}

// MARK: - Detection

private let osMemoryReserveGB: UInt64 = 4

public enum HardwareDetector: Sendable {

    public static func detect() throws -> HardwareInfo {
        let machineModel = try sysctlString("hw.model")
        let memoryBytes = try sysctlUInt64("hw.memsize")
        let memoryGb = memoryBytes / (1024 * 1024 * 1024)

        let cpuTotal = try sysctlUInt32("hw.ncpu")
        let cpuPerf = sysctlUInt32Optional("hw.perflevel0.logicalcpu") ?? cpuTotal
        let cpuEff = sysctlUInt32Optional("hw.perflevel1.logicalcpu") ?? 0

        let (chipName, gpuCores) = try detectGPUInfo()
        let (chipFamily, chipTier) = parseChipIdentity(chipName)
        let memoryBandwidthGbs = lookupBandwidth(
            family: chipFamily, tier: chipTier, gpuCores: gpuCores
        )
        let memoryAvailableGb = memoryGb > osMemoryReserveGB
            ? memoryGb - osMemoryReserveGB
            : 0

        return HardwareInfo(
            machineModel: machineModel,
            chipName: chipName,
            chipFamily: chipFamily,
            chipTier: chipTier,
            memoryGb: memoryGb,
            memoryAvailableGb: memoryAvailableGb,
            cpuCores: CpuCores(
                total: cpuTotal,
                performance: cpuPerf,
                efficiency: cpuEff
            ),
            gpuCores: gpuCores,
            memoryBandwidthGbs: memoryBandwidthGbs
        )
    }

    public static func totalMemoryGB() -> UInt64 {
        (try? sysctlUInt64("hw.memsize")).map { $0 / (1024 * 1024 * 1024) } ?? 16
    }
}

// MARK: - sysctl Helpers

func sysctlString(_ key: String) throws -> String {
    var size: Int = 0
    guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else {
        throw HardwareError.sysctlFailed(key)
    }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else {
        throw HardwareError.sysctlFailed(key)
    }
    return String(cString: buffer)
}

private func sysctlUInt64(_ key: String) throws -> UInt64 {
    var value: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    guard sysctlbyname(key, &value, &size, nil, 0) == 0 else {
        throw HardwareError.sysctlFailed(key)
    }
    return value
}

private func sysctlUInt32(_ key: String) throws -> UInt32 {
    var value: UInt32 = 0
    var size = MemoryLayout<UInt32>.size
    guard sysctlbyname(key, &value, &size, nil, 0) == 0 else {
        throw HardwareError.sysctlFailed(key)
    }
    return value
}

private func sysctlUInt32Optional(_ key: String) -> UInt32? {
    var value: UInt32 = 0
    var size = MemoryLayout<UInt32>.size
    guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return nil }
    return value
}

// MARK: - GPU Detection

private func detectGPUInfo() throws -> (chipName: String, gpuCores: UInt32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    process.arguments = ["SPDisplaysDataType", "-json"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    try process.run()

    // Drain stdout BEFORE waiting for exit. macOS pipe buffers hold only
    // ~512 bytes and system_profiler output exceeds that, so waiting first
    // deadlocks: the child blocks in write() while the parent blocks in
    // waitUntilExit(). readDataToEndOfFile() reads until the child closes
    // stdout, so it also serves as the join point; waitUntilExit() then reaps.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        return (fallbackChipName(), 0)
    }

    guard
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let displays = json["SPDisplaysDataType"] as? [[String: Any]]
    else {
        return (fallbackChipName(), 0)
    }

    for display in displays {
        guard let chipName = display["sppci_model"] as? String, !chipName.isEmpty else {
            continue
        }

        let gpuCores: UInt32 =
            (display["sppci_cores"] as? String).flatMap { UInt32($0) }
            ?? (display["sppci_gpu_core_count"] as? String).flatMap { UInt32($0) }
            ?? 0

        return (chipName, gpuCores)
    }

    return (fallbackChipName(), 0)
}

private func fallbackChipName() -> String {
    (try? sysctlString("machdep.cpu.brand_string")) ?? "Unknown Apple Silicon"
}

// MARK: - Chip Identity Parsing

internal func parseChipIdentity(_ chipName: String) -> (ChipFamily, ChipTier) {
    let name = chipName.lowercased()

    let family: ChipFamily
    if name.contains("m5") {
        family = .m5
    } else if name.contains("m4") {
        family = .m4
    } else if name.contains("m3") {
        family = .m3
    } else if name.contains("m2") {
        family = .m2
    } else if name.contains("m1") {
        family = .m1
    } else {
        family = .unknown
    }

    let tier: ChipTier
    if name.contains("ultra") {
        tier = .ultra
    } else if name.contains("max") {
        tier = .max
    } else if name.contains("pro") {
        tier = .pro
    } else if family != .unknown {
        tier = .base
    } else {
        tier = .unknown
    }

    return (family, tier)
}

// MARK: - Bandwidth Lookup

internal func lookupBandwidth(family: ChipFamily, tier: ChipTier, gpuCores: UInt32) -> UInt32 {
    switch (family, tier) {
    case (.m1, .base):  return 68
    case (.m1, .pro):   return 200
    case (.m1, .max):   return 400
    case (.m1, .ultra): return 800

    case (.m2, .base):  return 100
    case (.m2, .pro):   return 200
    case (.m2, .max):   return 400
    case (.m2, .ultra): return 800

    case (.m3, .base):  return 100
    case (.m3, .pro):   return 150
    case (.m3, .max):   return gpuCores >= 40 ? 400 : 300
    case (.m3, .ultra): return 819

    case (.m4, .base):  return 120
    case (.m4, .pro):   return 273
    case (.m4, .max):   return gpuCores >= 40 ? 546 : 410

    case (.m5, .base):  return 153
    case (.m5, .pro):   return 307
    case (.m5, .max):   return gpuCores >= 40 ? 614 : 460

    default: return 100
    }
}

// MARK: - GPU Peak FLOPS / Roofline Ridge
//
// Used ONLY to seed the adaptive-prefill chunk ladder from physics. macOS
// exposes neither GPU clock nor FLOPS, so — exactly like `lookupBandwidth` —
// these are small, explicit per-family tables. They are computed locally in the
// provider and are deliberately NOT added to the wire `HardwareInfo` (no
// protocol change / blast radius). Unknown family ⇒ nil/0 ⇒ seeding is skipped
// and the climber falls back to the generic empirical ladder.

/// Per-family GPU clock in GHz. Tier is accepted for future per-tier tuning;
/// today the clock is family-uniform. nil ⇒ unknown family.
internal func gpuClockGHz(family: ChipFamily, tier _: ChipTier) -> Double? {
    switch family {
    case .m1: return 1.28
    case .m2, .m3: return 1.40
    case .m4: return 1.80
    case .m5: return 1.90
    case .unknown: return nil
    }
}

/// FP16 FLOPs per GPU core per clock cycle. M1–M4 use the SIMD/vector ALU
/// throughput (≈512 FP16 FLOP/core/cycle, anchored to the verified M4 Max 40c
/// = 36.9 TFLOPS). M5 adds per-core matrix units (Neural Accelerators); 2048 is
/// an UNCERTAIN matrix-unit estimate and it is unverified whether the bundled
/// MLX dispatches prefill GEMM to them — the 8192 rung stays gated accordingly.
internal func flopPerCorePerCycle(family: ChipFamily) -> Double? {
    switch family {
    case .m1, .m2, .m3, .m4: return 512
    case .m5: return 2048
    case .unknown: return nil
    }
}

/// Peak FP16 throughput in FLOP/s = gpuCores × FLOP/core/cycle × clockGHz × 1e9.
/// Returns 0 for unknown family/tier or missing cores ⇒ seeding skipped.
internal func peakFp16Flops(family: ChipFamily, tier: ChipTier, gpuCores: UInt32) -> Double {
    guard gpuCores > 0,
          let clock = gpuClockGHz(family: family, tier: tier),
          let perCore = flopPerCorePerCycle(family: family)
    else { return 0 }
    return Double(gpuCores) * perCore * clock * 1e9
}

/// Roofline ridge point in FLOP/byte = peak FP16 FLOPS ÷ memory bandwidth.
/// Higher ridge ⇒ a larger prefill chunk is needed to become compute-bound.
/// Returns 0 when peak or bandwidth is unknown ⇒ seeding skipped.
internal func rooflineRidge(
    family: ChipFamily, tier: ChipTier, gpuCores: UInt32, memoryBandwidthGbs: UInt32
) -> Double {
    let peak = peakFp16Flops(family: family, tier: tier, gpuCores: gpuCores)
    guard peak > 0, memoryBandwidthGbs > 0 else { return 0 }
    return peak / (Double(memoryBandwidthGbs) * 1e9)
}

public extension HardwareInfo {
    /// Estimated peak FP16 throughput (FLOP/s). 0 ⇒ unknown hardware.
    var estimatedPeakFp16Flops: Double {
        peakFp16Flops(family: chipFamily, tier: chipTier, gpuCores: gpuCores)
    }

    /// Roofline ridge point (FLOP/byte). 0 ⇒ unknown hardware.
    var rooflineRidgeFlopPerByte: Double {
        rooflineRidge(
            family: chipFamily, tier: chipTier,
            gpuCores: gpuCores, memoryBandwidthGbs: memoryBandwidthGbs
        )
    }
}

// MARK: - Errors

public enum HardwareError: Error, CustomStringConvertible {
    case sysctlFailed(String)

    public var description: String {
        switch self {
        case .sysctlFailed(let key): return "sysctl query failed for '\(key)'"
        }
    }
}
