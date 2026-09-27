import Foundation
import Testing
@testable import ProviderCore

@Suite("Paged storage heartbeat provenance")
struct PagedStorageTelemetryTests {
    private func capture(
        _ id: UUID, sequence: UInt64, milliseconds: UInt64, committed: UInt64
    ) -> PagedStorageTelemetryCapture {
        var value = PagedStorageTelemetry()
        value.sampleSeq = sequence
        value.committedBytes = committed
        value.grantBytes = 2048
        return .init(sourceGeneration: id,
                     capturedUptimeNanoseconds: milliseconds * 1_000_000, value: value)
    }

    @Test("heartbeat age advances without renewing repeated or regressed captures")
    func repeatedCaptureKeepsItsOriginalAgeAndValues() throws {
        let id = UUID()
        var adapter = PagedStorageTelemetryAdapter()
        let firstValue = adapter.snapshot(
            capture(id, sequence: 8, milliseconds: 100, committed: 1024),
            nowUptimeNanoseconds: 110_000_000)
        let first = try #require(firstValue)
        #expect(first.sampleAgeMs == 10 && first.generation > 0)
        let repeatedValue = adapter.snapshot(
            capture(id, sequence: 8, milliseconds: 190, committed: 999),
            nowUptimeNanoseconds: 200_000_000)
        let repeated = try #require(repeatedValue)
        #expect(repeated.sampleSeq == 8 && repeated.sampleAgeMs == 100)
        #expect(repeated.committedBytes == 1024 && repeated.generation == first.generation)
        let olderValue = adapter.snapshot(
            capture(id, sequence: 7, milliseconds: 210, committed: 1),
            nowUptimeNanoseconds: 220_000_000)
        let older = try #require(olderValue)
        #expect(older.sampleSeq == 8 && older.sampleAgeMs == 120)
        #expect(older.committedBytes == 1024)
        let newerValue = adapter.snapshot(
            capture(id, sequence: 9, milliseconds: 225, committed: 512),
            nowUptimeNanoseconds: 230_000_000)
        let newer = try #require(newerValue)
        #expect(newer.sampleSeq == 9 && newer.sampleAgeMs == 5)
        #expect(newer.committedBytes == 512 && newer.generation == first.generation)
    }

    @Test("a new native pool starts a new numeric generation even at a lower sequence")
    func newPoolGenerationResetsTheCaptureBaseline() throws {
        var adapter = PagedStorageTelemetryAdapter()
        let oldValue = adapter.snapshot(
            capture(UUID(), sequence: 500, milliseconds: 100, committed: 10),
            nowUptimeNanoseconds: 110_000_000)
        let old = try #require(oldValue)
        let replacementValue = adapter.snapshot(
            capture(UUID(), sequence: 1, milliseconds: 120, committed: 0),
            nowUptimeNanoseconds: 130_000_000)
        let replacement = try #require(replacementValue)
        #expect(replacement.generation > 0 && replacement.generation != old.generation)
        #expect(replacement.sampleSeq == 1 && replacement.sampleAgeMs == 10)
        #expect(replacement.committedBytes == 0)
    }

    @Test("missing, uncaptured and future-dated observations are omitted")
    func unknownCaptureDoesNotForgeFreshness() throws {
        var adapter = PagedStorageTelemetryAdapter()
        #expect(adapter.snapshot(nil, nowUptimeNanoseconds: 100_000_000) == nil)
        #expect(adapter.snapshot(capture(UUID(), sequence: 0, milliseconds: 90, committed: 0),
                                 nowUptimeNanoseconds: 100_000_000) == nil)
        #expect(adapter.snapshot(capture(UUID(), sequence: 1, milliseconds: 110, committed: 0),
                                 nowUptimeNanoseconds: 100_000_000) == nil)
        let id = UUID()
        _ = adapter.snapshot(capture(id, sequence: 2, milliseconds: 100, committed: 10),
                             nowUptimeNanoseconds: 120_000_000)
        let backwardsValue = adapter.snapshot(
            capture(id, sequence: 3, milliseconds: 90, committed: 20),
            nowUptimeNanoseconds: 150_000_000)
        let backwards = try #require(backwardsValue)
        #expect(backwards.sampleSeq == 2 && backwards.sampleAgeMs == 50)
        #expect(backwards.committedBytes == 10)
        #expect(adapter.snapshot(nil, nowUptimeNanoseconds: 160_000_000) == nil)
    }

    @Test("wire shape retains nil versus zero and legacy slots omit paged_storage")
    func wireCompatibility() throws {
        var slot = BackendSlotCapacity(model: "fixture", state: "idle",
            numRunning: 0, numWaiting: 0, activeTokens: 0, maxTokensPotential: 0)
        let encoder = JSONEncoder()
        let oldData = try encoder.encode(slot)
        let old = try #require(JSONSerialization.jsonObject(with: oldData) as? [String: Any])
        #expect(old["paged_storage"] == nil)
        #expect(try JSONDecoder().decode(BackendSlotCapacity.self, from: oldData).pagedStorage == nil)
        var value = PagedStorageTelemetry()
        value.generation = 1
        value.sampleSeq = 2
        value.nominalKVBytes = 0
        value.allocationFailuresTotal = 0
        slot.pagedStorage = value
        let data = try encoder.encode(slot)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let wire = try #require(object["paged_storage"] as? [String: Any])
        #expect(wire["kind"] as? String == "segmented")
        #expect(wire["nominal_kv_bytes"] as? Int == 0)
        #expect(wire["allocation_failures_total"] as? Int == 0)
        #expect(wire["physical_floor_overhead_bytes"] == nil)
        #expect(wire["grant_epoch_retries_total"] == nil)
        let required: Set<String> = ["kind", "generation", "sample_seq", "sample_age_ms",
            "grant_bytes", "committed_bytes", "reserved_page_bytes", "live_page_bytes",
            "poison_bytes", "slack_bytes", "over_grant_bytes", "segment_count", "address_pages"]
        #expect(required.isSubset(of: Set(wire.keys)))
        #expect(try JSONDecoder().decode(BackendSlotCapacity.self, from: data).pagedStorage == value)
    }
}
