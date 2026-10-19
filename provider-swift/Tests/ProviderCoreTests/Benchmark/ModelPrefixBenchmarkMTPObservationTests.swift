import Foundation
import MLXLMCommon
import Testing

@Suite("Model prefix benchmark actual MTP work")
struct ModelPrefixBenchmarkMTPObservationTests {
    @Test("an installed but idle assistant cannot qualify a request")
    func inactiveOrIdle() {
        let missing = ModelPrefixBenchmarkMTPObservation(requested: true, before: nil, after: nil)
        #expect(!missing.qualified && missing.qualificationFailure == "inactive_engine")
        let idle = ModelPrefixBenchmarkMTPObservation(requested: true,
            before: CBv2MTPMetrics(), after: CBv2MTPMetrics())
        #expect(!idle.qualified && idle.qualificationFailure == "no_driver_work")
        let off = ModelPrefixBenchmarkMTPObservation(requested: false, before: nil, after: nil)
        #expect(off.qualified && !off.activeAfter && off.draftedTokens == 0)
        let unexpected = ModelPrefixBenchmarkMTPObservation(requested: false,
            before: nil, after: CBv2MTPMetrics())
        #expect(!unexpected.qualified)
    }

    @Test("actual rejected drafts qualify and cumulative work from an older row cannot leak")
    func scopedDriverWork() throws {
        var before = CBv2MTPMetrics()
        before.rounds = 9; before.draftedTokens = 20; before.acceptedTokens = 7
        before.serialVerificationRounds = 9; before.emittedTokens = 16
        var after = before
        after.rounds += 2; after.draftedTokens += 3
        after.serialVerificationRounds += 2; after.emittedTokens += 2
        let result = ModelPrefixBenchmarkMTPObservation(requested: true, before: before, after: after)
        #expect(result.qualified && result.rounds == 2 && result.draftedTokens == 3)
        #expect(result.acceptedTokens == 0 && result.serialVerificationRounds == 2)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result))
            as? [String: Any])
        #expect(object["requested"] as? Bool == true && object["qualified"] as? Bool == true)
        #expect(object["draftedTokens"] as? Int == 3)
        #expect(!ModelPrefixBenchmarkMTPObservation(requested: true,
            before: after, after: after).qualified)
        #expect(ModelPrefixBenchmarkMTPObservation(requested: true,
            before: after, after: before).qualificationFailure == "counter_regression")
    }

    @Test("fresh-process pair offsets validate through the actual benchmark specification")
    func specificationOffsets() throws {
        let input: [String: Any] = ["modelID": "synthetic", "openRouterID": "synthetic/model",
            "directory": "/tmp/synthetic", "expectedWeightHash": "synthetic", "modelType": "synthetic",
            "outputPath": "/tmp/synthetic-output.json", "pairs": 1, "outputTokens": 128,
            "cases": [["name": "short", "donorTokens": 1793, "sharedTokens": 1152,
                       "forkTokens": 2304, "demandedTokens": 1024]]]
        func decode(_ fields: [String: Any]) throws -> ModelPrefixBenchmarkSpecification {
            try JSONDecoder().decode(ModelPrefixBenchmarkSpecification.self,
                from: JSONSerialization.data(withJSONObject: fields))
        }
        let ordinary = try decode(input)
        try ordinary.validate()
        #expect(ordinary.mtpEnabled == nil && ordinary.pairOffset == nil)
        var configured = input
        configured["mtpEnabled"] = true; configured["pairOffset"] = 2
        let explicit = try decode(configured)
        try explicit.validate()
        #expect(explicit.mtpEnabled == true && explicit.pairOffset == 2)
        configured["pairOffset"] = 4; configured["pairs"] = 2
        let beyond = try decode(configured)
        #expect(throws: (any Error).self) { try beyond.validate() }
        configured["pairOffset"] = -1; configured["pairs"] = 1
        let negative = try decode(configured)
        #expect(throws: (any Error).self) { try negative.validate() }
    }
}
