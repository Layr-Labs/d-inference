import Foundation
import Testing
@testable import radix_engine

struct BenchmarkIdleObservationTests {
    private func idle(paged: Bool = true, shutdown: Bool = false, backing: Int = 0) -> [String: Any] {
        var result: [String: Any] = [
            "capacity": ["active_requests": 0, "waiting_requests": 0, "kv_in_use_bytes": 0,
                         "kv_reserved_bytes": backing, "steps_executed": 23],
            "process_memory": ["owner_count": shutdown ? 0 : 1, "closing_owner_count": 0,
                               "charged_bytes": backing, "materialized_bytes": backing,
                               "unmaterialized_bytes": 0],
            "ssd_cache": ["staged_bytes_in_use": 0, "write_host_bytes_in_use": 0],
            "mlx_memory": ["active_bytes": 20_000_000_000, "cache_bytes": 1_000_000_000],
        ]
        if paged {
            result["paged_storage"] = ["committed_bytes": backing, "segment_count": backing > 0 ? 1 : 0,
                                       "live_page_bytes": 0, "reserved_page_bytes": 0, "address_pages": 1050]
        }
        return result
    }

    @Test func staleTerminalGaugesWaitForPublishedIdleWithoutAdvancingSteps() async {
        var calls = 0
        let expected = idle()
        let metrics = await BenchmarkIdleObservation.capture(
            paged: true, shutdown: false, timeoutNanoseconds: 10,
            now: { UInt64(calls) }
        ) {
            calls += 1
            var value = expected
            if calls == 1 {
                value["capacity"] = ["active_requests": 1, "waiting_requests": 0,
                                     "kv_in_use_bytes": 100, "kv_reserved_bytes": 200,
                                     "steps_executed": 23]
            }
            return value
        }
        let observation = metrics["idle_observation"] as? [String: Any]
        #expect(observation?["status"] as? String == "ready")
        #expect(observation?["attempts"] as? Int == 2)
        #expect(observation?["elapsed_s"] as? Double == 2e-9)
        #expect((metrics["capacity"] as? [String: Int])?["steps_executed"] == 23)
        #expect(BenchmarkIdleObservation.failure(metrics) == nil)
    }

    @Test func deadlineRetainsLastUnretiredSnapshotAndFailure() async {
        var calls = 0
        let metrics = await BenchmarkIdleObservation.capture(
            paged: true, shutdown: false, timeoutNanoseconds: 2,
            now: { UInt64(calls) }
        ) {
            calls += 1
            var value = idle()
            value["capacity"] = ["active_requests": 1, "waiting_requests": 0,
                                 "kv_in_use_bytes": calls, "kv_reserved_bytes": calls]
            return value
        }
        let observation = metrics["idle_observation"] as? [String: Any]
        #expect(calls == 2)
        #expect(observation?["status"] as? String == "timed_out")
        #expect((metrics["capacity"] as? [String: Int])?["kv_in_use_bytes"] == 2)
        #expect((observation?["pending_retirement"] as? [String])?.contains("active_requests") == true)
        #expect(BenchmarkIdleObservation.failure(metrics)?.contains("timed_out") == true)
    }

    @Test func anIdleSnapshotArrivingAfterTheDeadlineStillTimesOut() async {
        var calls = 0
        let metrics = await BenchmarkIdleObservation.capture(
            paged: true, shutdown: false, timeoutNanoseconds: 1,
            now: { UInt64(calls) }
        ) {
            calls += 1
            return idle()
        }
        let observation = metrics["idle_observation"] as? [String: Any]
        #expect(observation?["status"] as? String == "timed_out")
        #expect((observation?["pending_retirement"] as? [String])?.isEmpty == true)
        #expect(BenchmarkIdleObservation.failure(metrics) != nil)
    }

    @Test func cancellationIsFailureEvenWhenTheLastSnapshotIsIdle() async {
        let metrics = await BenchmarkIdleObservation.capture(
            paged: true, shutdown: false, isCancelled: { true }
        ) { idle() }
        let observation = metrics["idle_observation"] as? [String: Any]
        #expect(observation?["status"] as? String == "cancelled")
        #expect(observation?["attempts"] as? Int == 1)
        #expect(BenchmarkIdleObservation.failure(metrics)?.contains("cancelled") == true)
        #expect(metrics["capacity"] != nil)
    }

    @Test func idleAllowsReusableBackingButRequiresItsExactAdmissionReservation() {
        let value = idle(backing: 64)
        #expect(BenchmarkIdleObservation.pendingRetirement(value, paged: true, shutdown: false).isEmpty)
        for reserved in [0, 63, 65] {
            var changed = value
            changed["capacity"] = ["active_requests": 0, "waiting_requests": 0,
                                   "kv_in_use_bytes": 0, "kv_reserved_bytes": reserved]
            #expect(BenchmarkIdleObservation.pendingRetirement(changed, paged: true, shutdown: false)
                .contains("kv_reservation_backing_mismatch"))
        }
    }

    @Test func missingBackingAndLivePagesCannotPassIdle() {
        for key in ["committed_bytes", "live_page_bytes", "reserved_page_bytes"] {
            var value = idle()
            var storage = value["paged_storage"] as! [String: Int]
            if key == "committed_bytes" { storage.removeValue(forKey: key) }
            else { storage[key] = 1 }
            value["paged_storage"] = storage
            #expect(BenchmarkIdleObservation.pendingRetirement(value, paged: true, shutdown: false).contains(key))
        }
    }

    @Test func shutdownRequiresEveryNativeOwnerAndBackingToRetire() {
        let value = idle(shutdown: true)
        #expect(BenchmarkIdleObservation.pendingRetirement(value, paged: true, shutdown: true).isEmpty)
        for key in ["owner_count", "closing_owner_count", "charged_bytes", "materialized_bytes", "unmaterialized_bytes"] {
            var changed = value
            var memory = changed["process_memory"] as! [String: Int]
            memory[key] = 1
            changed["process_memory"] = memory
            #expect(BenchmarkIdleObservation.pendingRetirement(changed, paged: true, shutdown: true).contains(key))
        }
        let retained = BenchmarkIdleObservation.pendingRetirement(idle(backing: 64), paged: true, shutdown: true)
        #expect(retained.contains("committed_bytes"))
        #expect(retained.contains("segment_count"))
    }

    @Test func stageAndWriterHostReservationsMustDrainForBothBackends() {
        for paged in [false, true] {
            for key in ["staged_bytes_in_use", "write_host_bytes_in_use"] {
                var value = idle(paged: paged)
                var ssd = value["ssd_cache"] as! [String: Int]
                ssd[key] = 1
                value["ssd_cache"] = ssd
                #expect(BenchmarkIdleObservation.pendingRetirement(value, paged: paged, shutdown: false).contains(key))
            }
        }
    }
}
