import Foundation
import MLXLMCommon

/// Explicit opt-in only. The caller starts and verifies its owner and supplies
/// a tokenizer; these factories never load a local model container or weights.
public enum DistributedEngineFactory {
    /// The single-Mac product's output default (`slotDefaultMaxTokens`).
    public static let defaultOutputTokens = 4096

    public static func makeBridge(
        owner: any DistributedResidentExecutionOwner,
        expectedIdentity: DistributedResidentIdentity,
        profile: DistributedResidentExecutionProfile,
        tokenizer: TokenizerHandle,
        eosTokenIDs: Set<Int>,
        firstTokenBudgetPolicy: DistributedFirstTokenBudgetPolicy? = nil,
        publicModelID: String? = nil,
        residentPrefixEvidence: ResidentPrefixCacheEvidence? = nil,
        modelType: String? = nil,
        modelDirectory: URL? = nil,
        pairTelemetry: DistributedPairTelemetryContext? = nil
    ) throws -> EngineV2Bridge {
        if let publicModelID { try validatePublicModelID(publicModelID) }
        guard eosTokenIDs.allSatisfy({ 0 <= $0 && $0 < profile.vocabularySize }) else {
            throw DistributedEngineError.invalidConfiguration("invalid EOS vocabulary")
        }
        try firstTokenBudgetPolicy?.validate(maximumPromptTokens: profile.maxPromptTokens)
        let engine = try DistributedCBv2Engine(
            owner: owner, expectedIdentity: expectedIdentity,
            profile: profile, detokenizers: CBv2TextDetokenizerFactory(tokenizer: tokenizer.inner),
            requestObserver: pairTelemetry?.observer() ?? DistributedRequestObservation.log)
        // The owner performs atomic per-peer admission. Parent MLX counters do
        // not measure remote allocations, so no invented parent byte charges are
        // attached here. The engine reports its owner's conservative capacity.
        // Prefix reuse happens on the peers (rank-local caches, agreed before
        // the first forward). With evidence the bridge mints a receipt per
        // request and advertises the frontiers both peers hold.
        // Product parity: the artifact's sampling defaults for the families
        // the product honours them for (legacy greedy defaults otherwise);
        // an omitted `max_tokens` is the product's 4,096 (the pair's output
        // limit), cut to the context left after the prompt.
        let modelID = publicModelID ?? expectedIdentity.modelID
        let samplingDefaults = EngineV2SamplingDefaults.resolve(
            modelId: modelID, modelType: modelType, modelDirectory: modelDirectory)
        return EngineV2Bridge(
            engine: engine, modelId: modelID, tokenizer: tokenizer,
            eosTokenIds: eosTokenIDs, samplingDefaults: samplingDefaults,
            defaultMaxTokens: min(defaultOutputTokens, profile.maxOutputTokens),
            defaultMaxTokensContextLimit: profile.maxContextTokens,
            maxConcurrentRequests: 1, residentPrefixCacheEvidence: residentPrefixEvidence,
            kvBackendKind: .contiguous, distributedFirstTokenBudgetPolicy: firstTokenBudgetPolicy)
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
        firstTokenBudgetPolicy: DistributedFirstTokenBudgetPolicy? = nil,
        residentPrefixEvidence: ResidentPrefixCacheEvidence? = nil,
        modelDirectory: URL? = nil,
        pairTelemetry: DistributedPairTelemetryContext? = nil
    ) throws -> MultiModelBatchSchedulerEngine.ModelRegistryEntry {
        let bridge = try makeBridge(
            owner: owner, expectedIdentity: expectedIdentity, profile: profile,
            tokenizer: tokenizer, eosTokenIDs: eosTokenIDs,
            firstTokenBudgetPolicy: firstTokenBudgetPolicy, publicModelID: publicModelID,
            residentPrefixEvidence: residentPrefixEvidence, modelType: modelType, modelDirectory: modelDirectory,
            pairTelemetry: pairTelemetry)
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
