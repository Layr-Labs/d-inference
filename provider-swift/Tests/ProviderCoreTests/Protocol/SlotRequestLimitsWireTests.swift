import Foundation
import Testing
@testable import ProviderCore

/// `request_limits` on a heartbeat slot, the shape Go `protocol.SlotRequestLimits`
/// decodes: snake_case integer tokens, the object omitted for a slot without
/// one, `serving_context_tokens` omitted (never zero) when no rank derives one.
@Suite("Slot request limits wire")
struct SlotRequestLimitsWireTests {
    private func slot(_ limits: SlotRequestLimits?) -> BackendSlotCapacity {
        BackendSlotCapacity(model: "EigenLabs/Qwen3.8-27B-4bit-mtp", state: "idle", numRunning: 0, numWaiting: 0,
                            activeTokens: 0, maxTokensPotential: 0, requestLimits: limits)
    }

    private func object(_ slot: BackendSlotCapacity) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(slot)) as? [String: Any])
    }

    @Test func aPairSlotCarriesItsLimitsInTokens() throws {
        let limits = SlotRequestLimits(maxPromptTokens: 262_143, maxOutputTokens: 65_536, maxContextTokens: 262_144,
                                       servingContextTokens: 200_000)
        let wire = try #require(try object(slot(limits))["request_limits"] as? [String: Int])
        #expect(wire == ["max_prompt_tokens": 262_143, "max_output_tokens": 65_536, "max_context_tokens": 262_144,
                         "serving_context_tokens": 200_000])
        #expect(try JSONDecoder().decode(BackendSlotCapacity.self, from: JSONEncoder().encode(slot(limits))).requestLimits == limits)
    }

    @Test func anUnstatedServingContextAndASoloSlotOmitTheirKeys() throws {
        let limits = SlotRequestLimits(maxPromptTokens: 32_768, maxOutputTokens: 32_768, maxContextTokens: 65_536)
        let wire = try #require(try object(slot(limits))["request_limits"] as? [String: Int])
        #expect(wire.keys.sorted() == ["max_context_tokens", "max_output_tokens", "max_prompt_tokens"])
        #expect(try object(slot(nil))["request_limits"] == nil)
        // A heartbeat from a provider that predates the field decodes as none.
        let legacy = Data(#"{"model":"m","state":"idle","num_running":0,"num_waiting":0}"#.utf8)
        #expect(try JSONDecoder().decode(BackendSlotCapacity.self, from: legacy).requestLimits == nil)
    }
}
