import Foundation
import MLXLMCommon

/// Explicit opt-in only. The caller starts and verifies its owner and supplies
/// a tokenizer; these factories never load a local model container or weights.
public enum DistributedEngineFactory {
    public static func makeBridge(
        owner: any DistributedResidentExecutionOwner,
        expectedIdentity: DistributedResidentIdentity,
        profile: DistributedResidentExecutionProfile,
        tokenizer: TokenizerHandle,
        eosTokenIDs: Set<Int>,
        firstTokenBudgetPolicy: DistributedFirstTokenBudgetPolicy? = nil,
        publicModelID: String? = nil
    ) throws -> EngineV2Bridge {
        if let publicModelID { try validatePublicModelID(publicModelID) }
        guard eosTokenIDs.allSatisfy({ 0 <= $0 && $0 < profile.vocabularySize }) else {
            throw DistributedEngineError.invalidConfiguration("invalid EOS vocabulary")
        }
        try firstTokenBudgetPolicy?.validate(maximumPromptTokens: profile.maxPromptTokens)
        let engine = try DistributedCBv2Engine(
            owner: owner, expectedIdentity: expectedIdentity,
            profile: profile, detokenizers: CBv2TextDetokenizerFactory(tokenizer: tokenizer.inner))
        // The owner performs atomic per-peer admission. Parent MLX counters do
        // not measure remote allocations, so no invented parent byte charges are
        // attached here. The engine reports its owner's conservative capacity.
        return EngineV2Bridge(
            engine: engine, modelId: publicModelID ?? expectedIdentity.modelID, tokenizer: tokenizer,
            eosTokenIds: eosTokenIDs, defaultMaxTokens: profile.maxOutputTokens,
            maxConcurrentRequests: 1, kvBackendKind: .contiguous,
            distributedFirstTokenBudgetPolicy: firstTokenBudgetPolicy)
    }

    /// Text-only registry construction for a successfully started installed
    /// session. The bridge takes owner ownership exactly as makeBridge does;
    /// the registry caller supplies acquisition/release pins and retains it
    /// through shutdown. A failed factory call leaves cleanup with the caller.
    public static func makeRegistryEntry(
        owner: any DistributedResidentExecutionOwner,
        expectedIdentity: DistributedResidentIdentity,
        publicModelID: String,
        profile: DistributedResidentExecutionProfile,
        tokenizer: TokenizerHandle,
        eosTokenIDs: Set<Int>,
        modelType: String? = nil,
        firstTokenBudgetPolicy: DistributedFirstTokenBudgetPolicy? = nil
    ) throws -> MultiModelBatchSchedulerEngine.ModelRegistryEntry {
        let bridge = try makeBridge(
            owner: owner, expectedIdentity: expectedIdentity, profile: profile,
            tokenizer: tokenizer, eosTokenIDs: eosTokenIDs,
            firstTokenBudgetPolicy: firstTokenBudgetPolicy, publicModelID: publicModelID)
        return .init(tokenizer: tokenizer, modelType: modelType, container: nil,
                     isVLM: false, engineV2Bridge: bridge, visionGate: nil)
    }

    /// Same public-route bounds as saved cluster configuration. The installed
    /// session must separately verify this ID against product ModelManifest.model_id.
    /// Native CheckpointManifest has no public ID; neither a rewrite nor equality
    /// with the native runtime's model identity is implied.
    private static func validatePublicModelID(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 }) else {
            throw DistributedEngineError.invalidConfiguration("invalid public model identity")
        }
    }
}
