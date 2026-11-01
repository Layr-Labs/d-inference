import Darwin
import Foundation
import MLX

/// Kernel- and allocator-reported memory for this process. Interval maxima are
/// tracked by the kernel, so a peak between two samples is not missed.
enum RunnerProcessMemory {
    struct Footprint {
        let current: UInt64
        let intervalMax: UInt64
        let lifetimeMax: UInt64
    }

    static func footprint() -> Footprint? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { return nil }
        return Footprint(current: info.ri_phys_footprint,
            intervalMax: info.ri_interval_max_phys_footprint,
            lifetimeMax: info.ri_lifetime_max_phys_footprint)
    }

    private typealias RlimitControl = @convention(c) (pid_t, Int32, UnsafeMutableRawPointer?) -> Int32
    // proc_rlimit_control is exported by libsystem_kernel but has no public
    // declaration. RLIMIT_FOOTPRINT_INTERVAL / FOOTPRINT_INTERVAL_RESET are in
    // <sys/resource.h>. Absence only disables the kernel interval reset.
    private static let rlimitControl: RlimitControl? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "proc_rlimit_control") else { return nil }
        return unsafeBitCast(symbol, to: RlimitControl.self)
    }()

    /// Resets the kernel's interval-maximum footprint and MLX's peak counter.
    @discardableResult
    static func resetPeaks() -> Bool {
        Memory.peakMemory = 0
        guard let control = rlimitControl else { return false }
        return control(getpid(), RLIMIT_FOOTPRINT_INTERVAL,
            UnsafeMutableRawPointer(bitPattern: UInt(FOOTPRINT_INTERVAL_RESET))) == 0
    }

    static func snapshot() -> RunnerJSON {
        let mlx = Memory.snapshot()
        var value: [String: RunnerJSON] = [
            "mlx_active": .bytes(mlx.activeMemory), "mlx_cache": .bytes(mlx.cacheMemory),
            "mlx_peak": .bytes(mlx.peakMemory),
        ]
        if let footprint = footprint() {
            value["phys_footprint"] = .bytes(footprint.current)
            value["phys_footprint_interval_max"] = .bytes(footprint.intervalMax)
            value["phys_footprint_lifetime_max"] = .bytes(footprint.lifetimeMax)
        }
        return .object(value)
    }
}
