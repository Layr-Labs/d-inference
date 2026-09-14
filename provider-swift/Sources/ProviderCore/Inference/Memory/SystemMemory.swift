import Foundation

/// Real, OS-reported available physical memory — what's actually free right now
/// accounting for macOS and every other process, not just what MLX is holding.
///
/// The model-load gate needs this: `total − MLX.active − MLX.cache` over-reports
/// free memory whenever the OS or other processes have consumed RAM, which on a
/// tight 24–64 GB box can let a load slip in that then drives the machine into
/// memory pressure / OOM before the per-request KV budget can intervene.
public enum SystemMemory {
    /// Available physical memory in bytes (free + inactive pages), or nil if the
    /// host statistics call fails. Inactive pages are reclaimable, so they count
    /// as available — matching how the OS reports "available".
    ///
    /// NOTE: `speculative_count` is deliberately NOT added: on macOS speculative
    /// pages are already counted inside `free_count` (the `vm_stat` tool prints
    /// "Pages free" as `free_count − speculative_count`). Adding speculative
    /// again over-reports available memory and would undercut the load gate's
    /// OOM-safety clamp.
    public static func availableBytes() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pages: UInt64 = 0
        for v in [UInt64(stats.free_count), UInt64(stats.inactive_count)] {
            let (sum, overflow) = pages.addingReportingOverflow(v)
            pages = overflow ? UInt64.max : sum
        }
        let (bytes, overflow) = pages.multipliedReportingOverflow(by: UInt64(getpagesize()))
        return overflow ? UInt64.max : bytes
    }
}
