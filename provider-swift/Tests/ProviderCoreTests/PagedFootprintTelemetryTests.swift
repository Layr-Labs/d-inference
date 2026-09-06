import Foundation
import Testing
@testable import ProviderCore

@Suite("Paged allocator footprint wire")
struct PagedFootprintTelemetryTests {
    @Test func canonicalFootprintAndLegacyOmission() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("coordinator/protocol/testdata/paged_footprint_wire.json")
        let data = try Data(contentsOf: fixture)
        var sample = try JSONDecoder().decode(PagedStorageTelemetry.self, from: data)
        #expect(sample.allocatorPaddingBytes == 50 && sample.lastAllocationAllowanceBytes == 77)
        let padding = try #require(sample.allocatorPaddingBytes)
        #expect(sample.committedBytes == sample.reservedPageBytes + sample.poisonBytes + sample.slackBytes + padding)
        let before = try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        let encoded = try JSONEncoder().encode(sample)
        let after = try #require(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        #expect(before == after)
        sample.allocatorPaddingBytes = nil; sample.lastAllocationAllowanceBytes = nil
        let legacyData = try JSONEncoder().encode(sample)
        let legacyWire = try #require(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        #expect(legacyWire["allocator_padding_bytes"] == nil && legacyWire["last_allocation_allowance_bytes"] == nil)
        let legacy = try JSONDecoder().decode(PagedStorageTelemetry.self, from: legacyData)
        #expect(legacy.allocatorPaddingBytes == nil && legacy.lastAllocationAllowanceBytes == nil)
    }
}
