import Foundation
import Testing
@testable import ProviderCore

@Test func servingPerformanceCapacityWireSymmetryAndLegacyOmission() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let fixture = root.appendingPathComponent("coordinator/tests/protocol/testdata/performance_capacity_wire_fixture.json")
    let capacity = try JSONDecoder().decode(BackendCapacity.self, from: Data(contentsOf: fixture))
    #expect(capacity.wholeMacServiceUsed == 0.5)
    #expect(capacity.wholeMacServiceRetirementProtocol == 1)
    #expect(capacity.wholeMacServiceReservations == [
        .init(id: "6e1f61d1-e22c-4d24-a3a7-d347772a48cb", usedFraction: 0.0625),
        .init(id: "9b3f32a9-3d08-4a71-b70a-dd5a2b2f140f", usedFraction: 0.125)])
    let profile = try #require(capacity.slots.first?.performanceProfile)
    #expect(profile.id == "test-reviewed-profile")
    #expect(profile.runtimeRevision == "cbv2-first-content-v1")
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
    #expect(slots[0]["deadline_profile"] == nil)
    #expect(slots[0]["prompt_work_identity"] == nil)
}

@Test func calibratedPerformanceCapacityWireSymmetry() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let fixture = root.appendingPathComponent("coordinator/tests/protocol/testdata/calibrated_capacity_wire_fixture.json")
    let capacity = try JSONDecoder().decode(BackendCapacity.self, from: Data(contentsOf: fixture))
    let slot = try #require(capacity.slots.first)
    let identity = try #require(slot.promptWorkIdentity)
    #expect(identity.modelArtifactHash == String(repeating: "a", count: 64))
    #expect(identity.promptContractID == String(repeating: "b", count: 64))
    let profile = try #require(slot.performanceProfile)
    #expect(profile.runtimeRevision == ServingPerformanceProfiles.runtimeRevision)
    #expect(profile.mtp?.artifactSha256 == String(repeating: "e", count: 64))
    #expect(profile.mtp?.fixedDraftTokens == 0)
    #expect(profile.mtp?.verificationMode == "automatic")
    let deadline = try #require(slot.deadlineProfile)
    #expect(deadline.id == "test-reviewed-deadline")
    #expect(deadline.configuredContextTokens == 262144 && deadline.effectiveMaxConcurrency == 16)
    #expect(deadline.prefillChunkSize == 512 && deadline.soloPrefillStripeTokens == 4096)
    #expect(deadline.mixedPrefillTokenCap == 256 && deadline.maxConcurrentPartialPrefills == 1)
    #expect(deadline.minimumWholeMacQuiescenceMs == 20_000)
    #expect(deadline.minimumNominalStabilityMs == 5_000 && deadline.powerMode == "automatic")
    #expect(deadline.mtp == profile.mtp)
    let work = try #require(slot.deadlineWork)
    #expect(work.version == 1 && work.known)
    #expect(work.epoch == slot.performanceMeasurements?.epoch)
    #expect(work.prefillTokens == 8192 && work.decodeTokens == 512 && work.requestCount == 2)
    #expect(work.contextTokensMax == 8704 && work.serviceFraction == 0.5)
    let restored = try JSONDecoder().decode(BackendCapacity.self, from: JSONEncoder().encode(capacity))
    #expect(restored == capacity)
}
