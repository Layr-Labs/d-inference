import Foundation
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol

/// Discovers an embedded assistant through the same native metadata quote
/// used for LOAD, then persists its exact policy. Starts no model or owner.
enum ClusterPlacementTensorAssistantSelection {
    static func arguments(modelDirectory: String, policy: ClusterQwenTensorAssistantPolicy,
                          promptTokens: Int, outputTokens: Int, lanes: Int, chunkTokens: Int) throws -> [String] {
        try policy.validate()
        guard [1, 2, 4, 8].contains(lanes), promptTokens > 0, outputTokens > 0, (1...512).contains(chunkTokens) else {
            throw ClusterConfigurationError.invalid("Invalid tensor assistant quotation scope")
        }
        return ["tensor-batch-scope", "--model-dir", modelDirectory,
            "--prompt-tokens", String(promptTokens), "--output-tokens", String(outputTokens),
            "--batch-lanes", String(lanes), "--chunk-size", String(chunkTokens), "--mtp-depth", String(policy.depth)] + policy.verificationArguments
    }

    static func read(tool: URL, modelDirectory: String, policy: ClusterQwenTensorAssistantPolicy,
                     promptTokens: Int, outputTokens: Int, lanes: Int, chunkTokens: Int,
                     deadline: UInt64) throws -> ClusterPlacementTensorBatchQuote {
        let quote = try ClusterPlacementTensorBatchQuote.decode(DistributedCapabilityProbe.run(executable: tool,
            arguments: arguments(modelDirectory: modelDirectory, policy: policy, promptTokens: promptTokens,
                outputTokens: outputTokens, lanes: lanes, chunkTokens: chunkTokens), deadline: deadline,
            maximumOutputBytes: ClusterPlacementTensorBatchQuote.maximumEncodedBytes))
        try quote.requireRequest(promptTokens: promptTokens, outputTokens: outputTokens, lanes: lanes, chunkTokens: chunkTokens)
        try quote.requireAssistant(policy)
        return quote
    }
    /// Discovery chooses a bounded depth; it never manufactures an inventory
    /// fingerprint. The native helper validates the exact registered artifact
    /// and headers before returning the policy and complete admission quote.
    /// Three: on the installed pair (c30) the head's first and second drafts
    /// were accepted 87% and 84% of the time, so a third proposal adds about
    /// 0.6 tokens a round for one more draft step, while the verify window
    /// stays bound by one weight pass.
    static let automaticDepth = 3

    static func automaticCandidate(mode: MTPMode, runtimeModelID: String,
                                   modelDirectory: URL, publicModelID: String,
                                   artifactSHA256: String, manifestSHA256: String,
                                   environment: [String: String]) throws -> Bool {
        guard mode != .off, SpecDecArtifactFunnel.killSwitchEnabled(environment: environment),
              runtimeModelID == ClusterQwenTensorAssistantPolicy.runtimeModelID else { return false }
        guard let manifest = ClusterSetupModelFolders.readManifest(modelDirectory.appendingPathComponent("manifest.json")),
              ClusterConfigurationCodec.sha256(manifest) == manifestSHA256 else {
            throw ClusterConfigurationError.invalid("The embedded assistant's manifest changed after capability discovery")
        }
        let artifact = try ClusterCatalogArtifact.parse(manifest: manifest)
        guard artifact.modelID == publicModelID, artifact.aggregateSHA256 == artifactSHA256 else {
            throw ClusterConfigurationError.invalid("The embedded assistant does not belong to this catalog artifact")
        }
        guard SpecDecStore.inlineDeclarationProbe(directory: modelDirectory).mayDeclareEmbeddedArtifact else { return false }
        switch SpecDecStore.inspectInlineArtifact(directory: modelDirectory) {
        case .success: return true
        case .failure(let failure):
            throw ClusterConfigurationError.invalid("The catalog model's embedded assistant is invalid: \(failure)")
        }
    }

    static func discoveryArguments(modelDirectory: String, promptTokens: Int, outputTokens: Int,
                                   chunkTokens: Int, assistant: Bool = true, lanes: Int = 1) throws -> [String] {
        guard promptTokens > 0, outputTokens > 0, (1...512).contains(chunkTokens), [1, 2, 4, 8].contains(lanes) else {
            throw ClusterConfigurationError.invalid("Invalid automatic tensor assistant quotation scope")
        }
        return ["tensor-batch-scope", "--model-dir", modelDirectory,
            "--prompt-tokens", String(promptTokens), "--output-tokens", String(outputTokens),
            "--batch-lanes", String(lanes), "--chunk-size", String(chunkTokens)] + (assistant ? ["--mtp-depth", String(automaticDepth),
            ClusterQwenTensorAssistantPolicy.verificationArgument,
            ClusterQwenTensorAssistantPolicy.Verification.admittedCohort.rawValue] : [])
    }

    static func requireDiscoveredQuote(_ quote: ClusterPlacementTensorBatchQuote,
                                       capability: ClusterRuntimeCapability, chunkTokens: Int, assistant: Bool = true,
                                       lanes: Int = 1) throws {
        try quote.validate()
        try quote.requireRequest(promptTokens: capability.profile.maximumPromptTokens,
            outputTokens: capability.profile.maximumOutputTokens, lanes: lanes, chunkTokens: chunkTokens)
        guard quote.request.runtimeModelID == capability.runtimeModelID,
              quote.request.artifactSHA256 == capability.artifactSHA256,
              quote.request.configurationSHA256 == capability.configurationSHA256,
              quote.request.maximumPromptTokens == capability.profile.maximumPromptTokens,
              quote.request.maximumOutputTokens == capability.profile.maximumOutputTokens,
              quote.request.maximumContextTokens == capability.profile.maximumContextTokens else {
            throw ClusterConfigurationError.invalid("Native discovery changed the tensor owner's artifact or complete request scope")
        }
        if assistant {
            guard let policy = quote.assistant?.policy, policy.depth == automaticDepth,
                  policy.verification == .admittedCohort else {
                throw ClusterConfigurationError.invalid("Native discovery changed the embedded assistant's verification policy")
            }
        } else { try quote.requireAssistant(nil) }
    }

    static func readAutomatic(tool: URL, modelDirectory: URL, publicModelID: String,
                              capability: ClusterRuntimeCapability, mode: MTPMode,
                              chunkTokens: Int, deadline: UInt64, lanes: Int = 1,
                              environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ClusterPlacementTensorBatchQuote? {
        guard capability.runtimeModelID == ClusterQwenTensorAssistantPolicy.runtimeModelID,
              !capability.hasPrivateImages else { return nil }
        let assistant = try automaticCandidate(mode: mode, runtimeModelID: capability.runtimeModelID,
            modelDirectory: modelDirectory, publicModelID: publicModelID, artifactSHA256: capability.artifactSHA256,
            manifestSHA256: capability.manifestSHA256, environment: environment)
        let quote = try ClusterPlacementTensorBatchQuote.decode(DistributedCapabilityProbe.run(executable: tool,
            arguments: discoveryArguments(modelDirectory: modelDirectory.path,
                promptTokens: capability.profile.maximumPromptTokens, outputTokens: capability.profile.maximumOutputTokens,
                chunkTokens: chunkTokens, assistant: assistant, lanes: lanes), deadline: deadline, maximumOutputBytes: ClusterPlacementTensorBatchQuote.maximumEncodedBytes))
        try requireDiscoveredQuote(quote, capability: capability, chunkTokens: chunkTokens, assistant: assistant, lanes: lanes)
        return quote
    }

}
