import Foundation
import Testing
@testable import ProviderCore

@Test func servingPerformanceCapacityWireSymmetryAndLegacyOmission() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let fixture = root.appendingPathComponent("coordinator/protocol/testdata/performance_capacity_wire_fixture.json")
    let capacity = try JSONDecoder().decode(BackendCapacity.self, from: Data(contentsOf: fixture))
    #expect(capacity.wholeMacServiceUsed == 0.5)
    let profile = try #require(capacity.slots.first?.performanceProfile)
    #expect(profile.id == "test-reviewed-profile")
    #expect(profile.runtimeRevision == ServingPerformanceProfiles.runtimeRevision)
    #expect(profile.contextTokens == 32768)
    let roundTrip = try JSONDecoder().decode(BackendCapacity.self, from: JSONEncoder().encode(capacity))
    #expect(roundTrip == capacity)
    var legacy = capacity
    legacy.wholeMacServiceUsed = nil
    legacy.slots[0].performanceProfile = nil
    let encoded = try JSONEncoder().encode(legacy)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["whole_mac_service_used"] == nil)
    let slots = try #require(object["slots"] as? [[String: Any]])
    #expect(slots[0]["performance_profile"] == nil)
}
