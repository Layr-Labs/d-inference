import Foundation
import Testing
@testable import MLXLMCommon
@testable import ProviderCore

private struct DeadlineDecisionFixture {
    struct Case: Decodable {
        let name: String
        let promptTokens: Int
        let targetComputedTokens: Int
        let maxOutputTokens: Int
        let schedulerPrefillTokens: Int
        let schedulerDecodeTokens: Int
        let existingContextTokensMax: Int
        let sameModelRequests: Int
        let sameModelPrefillTokens: Int
        let sameModelDecodeTokens: Int
        let observedPrefillTps: Double
        let observedDecodeTps: Double
        let cacheState: String
        let expectedBoundMs: Double
        let remainingMs: Double
        let qualified: Bool
        let admitted: Bool
    }
}

@Test func sharedCoordinatorDeadlineDecisions() throws {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: root.appendingPathComponent("coordinator/protocol").path) {
        let parent = root.deletingLastPathComponent()
        guard parent != root else { throw CocoaError(.fileNoSuchFile) }
        root = parent
    }
    let data = try Data(contentsOf: root.appendingPathComponent("coordinator/protocol/testdata/calibrated_deadline_decisions.json"))
    // The calibration uses explicit canonical wire keys; the case inputs use
    // ordinary snake-case conversion, independently of the release schema.
    let container = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let calibrationJSON = try #require(container["calibration"])
    let casesJSON = try #require(container["cases"])
    let calibration = try JSONDecoder().decode(DeadlineCalibration.self,
        from: JSONSerialization.data(withJSONObject: calibrationJSON))
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let cases = try decoder.decode([DeadlineDecisionFixture.Case].self,
        from: JSONSerialization.data(withJSONObject: casesJSON))
    #expect(calibration.isValid)
    #expect(cases.count >= 6)
    for row in cases {
        let policy = CBv2FirstContentCalibration(
            cells: calibration.cells.map { $0.engineCell(prefillCeiling: row.observedPrefillTps,
                decodeCeiling: row.observedDecodeTps) },
            evidenceGuard: .init(), sameModelRequests: row.sameModelRequests,
            otherModelRequests: 0, otherModelServiceFraction: 0, competitorProfileIDs: [],
            existingContextTokensMax: row.existingContextTokensMax,
            sameModelPrefillTokens: row.sameModelPrefillTokens,
            sameModelDecodeTokens: row.sameModelDecodeTokens)
        let seconds = policy.serviceSeconds(
            work: .init(prefillTokens: row.schedulerPrefillTokens, decodeTokens: row.schedulerDecodeTokens,
                scheduledSteps: 1, mixedSteps: 0),
            promptTokens: row.promptTokens, reusedPrefix: row.cacheState == "reused",
            activeRequests: row.sameModelRequests, maxOutputTokens: row.maxOutputTokens,
            targetComputedTokens: row.targetComputedTokens)
        #expect((seconds != nil) == row.qualified, "\(row.name)")
        if let seconds { #expect(abs(seconds * 1000 - row.expectedBoundMs) < 1e-8, "\(row.name)") }
        #expect((seconds.map { $0 * 1000 <= row.remainingMs } ?? false) == row.admitted, "\(row.name)")
    }
}
