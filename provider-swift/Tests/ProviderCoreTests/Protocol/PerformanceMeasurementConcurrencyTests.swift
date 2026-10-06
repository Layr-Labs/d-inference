import Foundation
import Testing
@testable import ProviderCore

@Test func MimoCalibrationConcurrencyWireKeepsLegacyOmissionAndMeasuredWidth() throws {
    var bucket = PerformanceWorkloadBucket(phase: "decode", promptTokenBucket: 1_024,
        contextTokenBucket: 1_024, cacheState: "cold", contention: "isolated",
        otherModelActivity: false,
        observation: .init(tokensPerSecond: 60, sampleCount: 1, sampleAgeMs: 0))
    let legacy = try JSONEncoder().encode(bucket)
    let legacyObject = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
    #expect(legacyObject["concurrent_requests"] == nil)
    #expect(try JSONDecoder().decode(PerformanceWorkloadBucket.self, from: legacy).concurrentRequests == nil)

    bucket.concurrentRequests = 4
    bucket.contention = "contended"
    let measured = try JSONEncoder().encode(bucket)
    let measuredObject = try #require(JSONSerialization.jsonObject(with: measured) as? [String: Any])
    #expect(measuredObject["concurrent_requests"] as? Int == 4)
    #expect(try JSONDecoder().decode(PerformanceWorkloadBucket.self, from: measured) == bucket)
}
