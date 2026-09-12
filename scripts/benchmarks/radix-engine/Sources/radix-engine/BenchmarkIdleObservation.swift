import Foundation

/// A terminal event may arrive before the owner queue publishes its final
/// gauges. Observe retirement only where the harness knows no request remains.
/// This reads immutable snapshots; it never refreshes or mutates native state.
enum BenchmarkIdleObservation {
    static let timeoutNanoseconds: UInt64 = 5_000_000_000

    static func capture(
        paged: Bool, shutdown: Bool,
        timeoutNanoseconds: UInt64 = BenchmarkIdleObservation.timeoutNanoseconds,
        now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        isCancelled: () -> Bool = { Task.isCancelled },
        snapshot: () async -> [String: Any]
    ) async -> [String: Any] {
        let started = now()
        var attempts = 0
        while true {
            var metrics = await snapshot()
            attempts += 1
            let reasons = pendingRetirement(metrics, paged: paged, shutdown: shutdown)
            let elapsed = now() - started
            let status: String?
            if isCancelled() { status = "cancelled" }
            else if elapsed >= timeoutNanoseconds { status = "timed_out" }
            else if reasons.isEmpty { status = "ready" }
            else { status = nil }
            if let status {
                // Preserve the final observed tuple even when it cannot pass.
                metrics["idle_observation"] = [
                    "status": status, "shutdown": shutdown, "attempts": attempts,
                    "elapsed_s": Double(elapsed) / 1_000_000_000,
                    "timeout_s": Double(timeoutNanoseconds) / 1_000_000_000,
                    "pending_retirement": reasons,
                ] as [String: Any]
                return metrics
            }
            await Task.yield()
        }
    }

    static func failure(_ metrics: [String: Any]) -> String? {
        guard let observation = metrics["idle_observation"] as? [String: Any],
              let status = observation["status"] as? String, status != "ready" else { return nil }
        let reasons = observation["pending_retirement"] as? [String] ?? []
        return "idle observation \(status)" + (reasons.isEmpty ? "" : ": " + reasons.joined(separator: ", "))
    }

    static func pendingRetirement(
        _ metrics: [String: Any], paged: Bool, shutdown: Bool
    ) -> [String] {
        var pending: [String] = []
        func requireZero(_ values: [String: Any], _ keys: [String]) {
            for key in keys where integer(values[key]) != 0 { pending.append(key) }
        }
        let capacity = metrics["capacity"] as? [String: Any] ?? [:]
        requireZero(capacity, ["active_requests", "waiting_requests", "kv_in_use_bytes"])
        var backing: UInt64? = 0
        if paged {
            let storage = metrics["paged_storage"] as? [String: Any] ?? [:]
            requireZero(storage, ["live_page_bytes", "reserved_page_bytes"])
            backing = integer(storage["committed_bytes"])
            if backing == nil { pending.append("committed_bytes") }
            if shutdown { requireZero(storage, ["committed_bytes", "segment_count"]) }
        }
        if backing == nil || integer(capacity["kv_reserved_bytes"]) != backing {
            pending.append("kv_reservation_backing_mismatch")
        }
        if let ssd = metrics["ssd_cache"] as? [String: Any] {
            requireZero(ssd, ["staged_bytes_in_use", "write_host_bytes_in_use"])
        }
        if let attention = metrics["ssd_attention_cache"] as? [String: Any] {
            requireZero(attention, ["staged_bytes_in_use"])
        }
        let memory = metrics["process_memory"] as? [String: Any] ?? [:]
        if shutdown {
            requireZero(memory, ["owner_count", "closing_owner_count", "charged_bytes",
                                 "materialized_bytes", "unmaterialized_bytes"])
        }
        // Reusable committed segments may remain at normal idle. Address pages,
        // MLX weights/cache and RSS are not retired ownership and need not be zero.
        return pending
    }

    private static func integer(_ value: Any?) -> UInt64? {
        if let value = value as? Int, value >= 0 { return UInt64(value) }
        return value as? UInt64
    }
}
