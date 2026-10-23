import Foundation

/// OS memory headroom under the process-start admission policy. Reclaimable
/// file-backed pages can hold files other processes are using; reclaimability
/// does not guarantee free RAM.
public enum SystemMemory {
    public enum AvailabilityPolicy: String, Sendable {
        case reclaimable
        case freeOnly = "free-only"

        /// Preserve the default when unset. An invalid explicit value fails
        /// toward the stricter policy rather than granting reclaim credit.
        public static func resolve(_ value: String?) -> Self {
            guard let value else { return .reclaimable }
            return Self(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                ?? .freeOnly
        }
    }

    public static let availabilityEnvironmentKey = "DARKBLOOM_MEMORY_AVAILABILITY"
    public static let availabilityPolicy = AvailabilityPolicy.resolve(
        ProcessInfo.processInfo.environment[availabilityEnvironmentKey])

    /// Every live admission consumer uses the same policy. The default
    /// `reclaimable` policy counts free pages plus the file-backed page cache
    /// and volatile purgeable pages: the kernel drops clean cache (and writes
    /// back dirty cache) without compressing or swapping any process memory, so
    /// cached model files never block a load. Anonymous pages, active or
    /// inactive, and compressor pages are never counted. It returns nil on
    /// sampling failure. `free-only` counts only free pages and returns zero on
    /// failure, so callers' `?? .max` fallback cannot bypass the stricter gate.
    public static func availableBytes() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        return availableBytes(
            stats: result == KERN_SUCCESS ? stats : nil,
            pageSize: UInt64(getpagesize()), policy: availabilityPolicy)
    }

    /// Pure conversion shared by the live sampler and regression tests.
    ///
    /// Mach partitions pageable pages as `active + inactive + speculative +
    /// throttled == internal_page_count + external_page_count`, and
    /// `free_count` already includes the speculative pages (`vm_stat` prints
    /// "Pages free" as `free_count − speculative_count`). Speculative pages are
    /// file read-ahead, so they sit inside both `free_count` and
    /// `external_page_count`; the reclaimable sum counts them once.
    /// `external_page_count` is pageable file-backed pages only (wired pages
    /// are excluded) and `purgeable_count` is unwired volatile purgeable pages.
    static func availableBytes(
        stats: vm_statistics64?, pageSize: UInt64, policy: AvailabilityPolicy
    ) -> UInt64? {
        guard let stats, pageSize > 0 else {
            return policy == .freeOnly ? 0 : nil
        }
        let free = UInt64(stats.free_count)
        let counted: [UInt64]
        switch policy {
        case .freeOnly:
            counted = [free]
        case .reclaimable:
            let freeExcludingSpeculative = free - min(free, UInt64(stats.speculative_count))
            counted = [
                freeExcludingSpeculative, UInt64(stats.external_page_count),
                UInt64(stats.purgeable_count),
            ]
        }
        var pages: UInt64 = 0
        for v in counted {
            let (sum, overflow) = pages.addingReportingOverflow(v)
            pages = overflow ? UInt64.max : sum
        }
        let (bytes, overflow) = pages.multipliedReportingOverflow(by: pageSize)
        return overflow ? (policy == .freeOnly ? 0 : UInt64.max) : bytes
    }
}
