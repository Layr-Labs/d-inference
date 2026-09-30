import Foundation

/// OS memory headroom under the process-start admission policy. Inactive pages
/// can belong to other processes; reclaimability does not guarantee free RAM.
public enum SystemMemory {
    public enum AvailabilityPolicy: String, Sendable {
        case reclaimable
        case freeOnly = "free-only"

        /// Preserve the legacy default when unset. An invalid explicit value
        /// fails toward the stricter policy rather than granting reclaim credit.
        public static func resolve(_ value: String?) -> Self {
            guard let value else { return .reclaimable }
            return Self(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                ?? .freeOnly
        }
    }

    public static let availabilityEnvironmentKey = "DARKBLOOM_MEMORY_AVAILABILITY"
    public static let availabilityPolicy = AvailabilityPolicy.resolve(
        ProcessInfo.processInfo.environment[availabilityEnvironmentKey])

    /// Every live admission consumer uses the same policy. Legacy mode counts
    /// free + inactive pages and returns nil on sampling failure. Free-only mode
    /// counts no inactive pages and returns zero on failure, so callers' legacy
    /// `?? .max` fallback cannot bypass the stricter gate.
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
        return availableBytes(
            freePages: result == KERN_SUCCESS ? UInt64(stats.free_count) : nil,
            inactivePages: UInt64(stats.inactive_count),
            pageSize: UInt64(getpagesize()), policy: availabilityPolicy)
    }

    /// Pure conversion shared by the live sampler and regression tests.
    static func availableBytes(
        freePages: UInt64?, inactivePages: UInt64, pageSize: UInt64,
        policy: AvailabilityPolicy
    ) -> UInt64? {
        guard let freePages, pageSize > 0 else {
            return policy == .freeOnly ? 0 : nil
        }
        var pages: UInt64 = 0
        for v in [freePages, policy == .reclaimable ? inactivePages : 0] {
            let (sum, overflow) = pages.addingReportingOverflow(v)
            pages = overflow ? UInt64.max : sum
        }
        let (bytes, overflow) = pages.multipliedReportingOverflow(by: pageSize)
        return overflow ? (policy == .freeOnly ? 0 : UInt64.max) : bytes
    }
}
