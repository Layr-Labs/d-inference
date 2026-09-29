import Foundation
import Testing
@testable import ProviderCore

@Test func servingPerformanceCapacityWireSymmetryAndLegacyOmission() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let fixture = root.appendingPathComponent("coordinator/protocol/testdata/performance_capacity_wire_fixture.json")
    let capacity = try JSONDecoder().decode(BackendCapacity.self, from: Data(contentsOf: fixture))
    #expect(capacity.wholeMacServiceUsed == 0.5)
    #expect(capacity.wholeMacServiceRetirementProtocol == 1)
    #expect(capacity.wholeMacServiceReservations == [
        .init(id: "6e1f61d1-e22c-4d24-a3a7-d347772a48cb", usedFraction: 0.0625),
        .init(id: "9b3f32a9-3d08-4a71-b70a-dd5a2b2f140f", usedFraction: 0.125)])
    let profile = try #require(capacity.slots.first?.performanceProfile)
    #expect(profile.id == "test-reviewed-profile")
    #expect(profile.runtimeRevision == ServingPerformanceProfiles.runtimeRevision)
    #expect(profile.contextTokens == 32768)
    let roundTrip = try JSONDecoder().decode(BackendCapacity.self, from: JSONEncoder().encode(capacity))
    #expect(roundTrip == capacity)
    var legacy = capacity
    legacy.wholeMacServiceUsed = nil
    legacy.wholeMacServiceRetirementProtocol = nil
    legacy.wholeMacServiceReservations = []
    legacy.slots[0].performanceProfile = nil
    let encoded = try JSONEncoder().encode(legacy)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["whole_mac_service_used"] == nil)
    #expect(object["whole_mac_service_retirement_protocol"] == nil)
    #expect(object["whole_mac_service_reservations"] == nil)
    let slots = try #require(object["slots"] as? [[String: Any]])
    #expect(slots[0]["performance_profile"] == nil)
}
