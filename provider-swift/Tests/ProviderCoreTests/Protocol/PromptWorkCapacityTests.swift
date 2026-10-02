import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

@Test func promptWorkCapacityAdvertisesFactoryIdentityWithoutProfiles() async throws {
    let identity = PromptWorkIdentity(modelArtifactHash: String(repeating: "a", count: 64),
        promptContractID: String(repeating: "b", count: 64))
    let bridge = EngineV2Bridge(engine: PrefillScriptEngine(), modelId: "model",
        tokenizer: TokenizerHandle(PromptWorkCapacityTokenizer()), eosTokenIds: [],
        promptWorkIdentity: identity)
    let slot = await bridge.backendSlotCapacity()
    #expect(slot.promptWorkIdentity == identity)
    #expect(slot.performanceProfile == nil && slot.deadlineProfile == nil)
    let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(slot)) as? [String: Any])
    let pair = try #require(wire["prompt_work_identity"] as? [String: String])
    #expect(pair == ["model_artifact_hash": identity.modelArtifactHash, "prompt_contract_id": identity.promptContractID])
    #expect(try JSONDecoder().decode(BackendSlotCapacity.self, from: JSONEncoder().encode(slot)) == slot)
    await bridge.shutdown()
}

private struct PromptWorkCapacityTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "test" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] { [1] }
}
