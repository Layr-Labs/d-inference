import Foundation
import MLXLMCommon
import DarkbloomClusterProtocol

/// Explicit opt-in only. The caller starts and verifies its owner and supplies
/// a tokenizer; these factories never load a local model container or weights.
public enum DistributedEngineFactory {
    /// The cluster output allowance; the bridge also clamps it to the model's
    /// advertised output maximum and the request's remaining context.
    public static let defaultOutputTokens = ClusterWorkerLimits.outputTokens

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
        if profile.id == ClusterMiMoImageCandidate.profileID {
            guard modelType == "mimo_v2",expectedIdentity.modelID == ClusterMiMoImageCandidate.runtimeModelID,
                  expectedIdentity.artifactSHA256 == ClusterMiMoImageCandidate.artifactSHA256,
                  expectedIdentity.configurationSHA256 == ClusterMiMoImageCandidate.configurationSHA256 else {
                throw DistributedEngineError.invalidConfiguration("Private image profile does not bind the actual installed MiMo model")
            }
        }
        let modelID = publicModelID ?? expectedIdentity.modelID
        // Product parity: the single-Mac slot's stop set, from the same files
        // by the same rules (`EngineV2SlotFactory`).
        let stopTokenIDs = productStopTokenIDs(installed: eosTokenIDs, modelID: modelID, modelType: modelType,
                                               modelDirectory: modelDirectory, tokenizer: tokenizer)
        guard stopTokenIDs.allSatisfy({ 0 <= $0 && $0 < profile.vocabularySize }) else {
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
        // an omitted `max_tokens` is the product's 32,768 (the pair's output
        // limit), cut to the context left after the prompt.
        let samplingDefaults = EngineV2SamplingDefaults.resolve(
            modelId: modelID, modelType: modelType, modelDirectory: modelDirectory)
        var draftMiMoImageConfiguration: Data?
        if profile.id == ClusterMiMoImageCandidate.profileID {
            guard let modelDirectory else { throw DistributedEngineError.invalidConfiguration("MiMo image metadata missing") }
            let url = modelDirectory.appendingPathComponent("config.json")
            let attrs = try FileManager.default.attributesOfItem(atPath:url.path)
            guard let size = attrs[.size] as? NSNumber,size.intValue > 0,size.intValue <= 1_048_576 else {
                throw DistributedEngineError.invalidConfiguration("MiMo image configuration exceeds bound")
            }
            let bytes = try Data(contentsOf:url)
            _ = try DistributedMiMoImageIngress(configuration:bytes,expectedSHA256:expectedIdentity.configurationSHA256)
            draftMiMoImageConfiguration = bytes
        }
        var clusterGLMImageConfiguration: Data?
        if profile.id == ClusterGLMImageCandidate.profileID {
            guard modelType == "glm5_next" else { throw DistributedEngineError.invalidConfiguration("GLM image profile on another model") }
            try ClusterGLMImageCandidate.validateSource(profileID: profile.id, modelID: expectedIdentity.modelID,
                artifact: expectedIdentity.artifactSHA256, configuration: expectedIdentity.configurationSHA256)
            guard profile.id == ClusterStillImages.glmProfileID, let modelDirectory else {
                throw DistributedEngineError.invalidConfiguration("GLM image metadata missing")
            }
            let handle = try FileHandle(forReadingFrom: modelDirectory.appendingPathComponent("config.json"))
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: 32 * 1024 * 1024 + 1) ?? Data()
            _ = try DistributedGLMImageIngress(configuration: bytes, expectedSHA256: expectedIdentity.configurationSHA256)
            clusterGLMImageConfiguration = bytes
        }
        return EngineV2Bridge(
            engine: engine, modelId: modelID, tokenizer: tokenizer,
            eosTokenIds: stopTokenIDs, samplingDefaults: samplingDefaults,
            defaultMaxTokens: min(defaultOutputTokens, profile.maxOutputTokens),
            defaultMaxTokensContextLimit: profile.maxContextTokens,
            // As many requests at once as the pair batches (its lanes); the
            // owner's own admission still bounds and refuses beyond them.
            maxConcurrentRequests: max(1, owner.concurrentRequests), residentPrefixCacheEvidence: residentPrefixEvidence,
            kvBackendKind: .contiguous, distributedFirstTokenBudgetPolicy: firstTokenBudgetPolicy,
            draftMiMoImageConfiguration:draftMiMoImageConfiguration, clusterGLMImageConfiguration:clusterGLMImageConfiguration)
    }

    /// Registry construction for a successfully started installed
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

    /// The stop set a single-Mac slot of this model serves with
    /// (`EngineV2SlotFactory`): the artifact's EOS as the model loader reads
    /// it (`ModelEOSPolicy.artifactEOSTokenIds`) plus the model's EOS policy
    /// (GPT-OSS/Harmony stops at `<|call|>`, `<|return|>` and
    /// `<|endoftext|>`). The bridge adds the tokenizer's EOS, as it does for
    /// a single-Mac slot. The installed model's EOS is the base only when the
    /// directory has no model configuration.
    static func productStopTokenIDs(installed: Set<Int>, modelID: String, modelType: String?,
                                    modelDirectory: URL?, tokenizer: TokenizerHandle) -> Set<Int> {
        let base = modelDirectory.flatMap { ModelEOSPolicy.artifactEOSTokenIds(modelDirectory: $0) } ?? installed
        return ModelEOSPolicy.effectiveEOSTokenIds(modelId: modelID, modelType: modelType, base: base,
                                                   tokenToId: { tokenizer.inner.convertTokenToId($0) })
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
