import Foundation
import Testing

@testable import ProviderCore

@Suite("Deadline decision wire contract")
struct DeadlineDecisionProfileTests {
    @Test("unknown values fold and old profiles keep the object absent")
    func unknownAndLegacy() throws {
        let decoder = JSONDecoder()
        let old = try decoder.decode(InferenceProfile.self, from: Data(#"{"schema":1}"#.utf8))
        #expect(old.deadlineDecision == nil)
        let encoded = try JSONEncoder().encode(old)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["deadline_decision"] == nil)

        let data = Data(#"{"verdict":"future","continuation":"future","projection":"future","projection_reason":"future","future_key":"ignored"}"#.utf8)
        let decision = try decoder.decode(DeadlineDecisionProfile.self, from: data)
        #expect(decision.verdict == .other)
        #expect(decision.continuation == .other)
        #expect(decision.projection == .other)
        #expect(decision.projectionReason == .other)
        #expect(DeadlineVerdict.allCases.map(\.rawValue) == [
            "accepted", "deadline_unreachable", "expired_before_submit", "cancelled", "other",
        ])
        #expect(DeadlineContinuation.allCases.map(\.rawValue) == ["expired", "cancelled", "other"])
        #expect(DeadlineProjection.allCases.map(\.rawValue) == ["bounded", "unbounded", "not_attempted", "other"])
        #expect(DeadlineProjectionReason.allCases.map(\.rawValue) == [
            "no_deadline", "mode_off", "unsupported_scheduler", "multimodal", "unmeasured_prefill", "other",
        ])
    }

    @Test("wire bounds apply to new fields and unavailable rates stay absent")
    func saturation() throws {
        var d = DeadlineDecisionProfile()
        d.observedUs = .max
        d.remainingUs = -1
        d.submitRemainingUs = .max
        d.projectedServiceUs = .max
        d.projectedPrefillTokens = .max
        d.projectedDecodeTokens = -1
        d.prefillTps = .infinity
        d.decodeTps = .nan
        var profile = InferenceProfile()
        profile.deadlineDecision = d
        let wire = try #require(profile.saturatedToWireRanges().deadlineDecision)
        #expect(wire.observedUs == InferenceProfile.maxWireMicros)
        #expect(wire.remainingUs == 0)
        #expect(wire.submitRemainingUs == InferenceProfile.maxWireMicros)
        #expect(wire.projectedServiceUs == InferenceProfile.maxWireMicros)
        #expect(wire.projectedPrefillTokens == InferenceProfile.maxWireCount)
        #expect(wire.projectedDecodeTokens == 0)
        #expect(wire.prefillTps == nil)
        #expect(wire.decodeTps == nil)
        _ = try JSONEncoder().encode(wire)
        d.prefillTps = 2_000_000_000
        d.decodeTps = -1
        #expect(d.saturatedToWireRanges().prefillTps == 1_000_000_000)
        #expect(d.saturatedToWireRanges().decodeTps == nil)
    }
}
