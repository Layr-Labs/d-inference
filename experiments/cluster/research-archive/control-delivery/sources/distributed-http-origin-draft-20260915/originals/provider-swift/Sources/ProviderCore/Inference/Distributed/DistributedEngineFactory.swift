import Foundation
import MLXLMCommon

/// Explicit opt-in only. No model loading, default factory registration, local
/// endpoint wiring or MTP casts are changed by this experimental seam.
public enum DistributedEngineFactory {
    public static func makeBridge(
        owner: any DistributedResidentExecutionOwner,
        expectedIdentity: DistributedResidentIdentity,
        profile: DistributedResidentExecutionProfile,
        tokenizer: TokenizerHandle,
        eosTokenIDs: Set<Int>
    ) throws -> EngineV2Bridge {
        guard eosTokenIDs.allSatisfy({ 0 <= $0 && $0 < profile.vocabularySize }) else {
            throw DistributedEngineError.invalidConfiguration("invalid EOS vocabulary")
        }
        let engine = try DistributedCBv2Engine(
            owner: owner, expectedIdentity: expectedIdentity,
            profile: profile, detokenizers: CBv2TextDetokenizerFactory(tokenizer: tokenizer.inner))
        // The owner performs atomic per-peer admission. Parent MLX counters do
        // not measure remote allocations, so no invented parent byte charges are
        // attached here. The engine reports its owner's conservative capacity.
        return EngineV2Bridge(
            engine: engine, modelId: expectedIdentity.modelID, tokenizer: tokenizer,
            eosTokenIds: eosTokenIDs, defaultMaxTokens: profile.maxOutputTokens,
            maxConcurrentRequests: 1, kvBackendKind: .contiguous)
    }
}
