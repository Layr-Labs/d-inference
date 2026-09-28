import Darwin
import Foundation
import MLX
import Metal

@testable import ProviderCore

extension ProviderLoop {
    /// Phase-aligned numeric evidence, not a second admission policy or an
    /// assertion that a larger machine qualifies a smaller hardware tier.
    func recordFlashNextLifecycleMemory(_ phase: String) {
        let sample = kvBudget.memoryHeadroomSnapshot()
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var fields: [String: Any] = [
            "kind": "flash_next_lifecycle_memory", "phase": phase,
            "uptime_ns": sample.capturedUptimeNanoseconds,
            "physical_bytes": sample.totalBytes, "mlx_active_bytes": sample.activeBytes,
            "mlx_cache_bytes": sample.cacheBytes, "mlx_peak_bytes": Memory.peakMemory,
            "system_available_bytes": sample.systemAvailableBytes,
            "runtime_remaining_bytes": sample.runtimeRemainingBytes,
            "unmaterialized_bytes": sample.unmaterializedCommittedBytes,
            "native_charge_bytes": sample.totalOwnedBytes,
            "materialized_bytes": sample.materializedBytes,
            "cap_bytes": sample.capBytes,
            "activation_reserve_bytes": sample.activationReserveBytes,
            "memory_policy_epoch": sample.policyEpoch,
            "owner_count": sample.ownerCount, "closing_owner_count": sample.closingOwnerCount,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            fields["metal_allocated_bytes"] = device.currentAllocatedSize
        }
        if result == KERN_SUCCESS {
            fields["process_footprint_bytes"] = info.phys_footprint
            fields["process_footprint_peak_bytes"] = info.ledger_phys_footprint_peak
        }
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
    }
}
