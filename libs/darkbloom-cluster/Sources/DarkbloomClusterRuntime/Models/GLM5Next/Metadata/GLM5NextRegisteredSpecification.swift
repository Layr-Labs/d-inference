import DarkbloomClusterProtocol
import Foundation
import MLXLLM

/// The GLM artifacts the layer-pipeline adapter serves. Closed: an ID or a
/// configuration outside this enumeration has no specification.
enum GLM5NextRegisteredModel: String, CaseIterable {
    case glm53Flash = "registered_glm53_flash"
}

/// One closed row per registered GLM artifact: its pinned identities (the
/// `GLM5NextArtifactPin` the header inventory was checked against) and the
/// cut, schedule and mode scope of its resident pair. Describing a model
/// allocates nothing and admits no request.
struct GLM5NextRegisteredSpecification {
    let model: GLM5NextRegisteredModel
    let profileID: String
    let repository: String, revision: String
    let configurationSHA256: String, manifestSHA256: String, artifactSHA256: String
    let inventorySHA256: String
    let manifestBytes: Int, manifestFileCount: Int
    let layers: Int, hidden: Int, vocabulary: Int
    /// `max_position_embeddings` of the pinned configuration; the request
    /// limits follow from it (`contextLimits`).
    let declaredContextTokens: Int
    let storage: GLM5NextWeightInventory.Storage
    let executionPolicy: GLM5NextExecutionPolicy
    /// Every layer boundary: only the four-stream residual crosses a cut and
    /// each layer owns its own attention state. Not a memory or speed claim;
    /// the planner chooses from what each Mac detects and the load gates decide.
    var supportedCuts: [Int] { Array(1..<layers) }
    let supportedPrefillSchedules: [ClusterPrefillSchedule]
    let supportedGenerationModes: [ClusterGenerationMode]

    /// GLM NVFP4 declares per-expert packing in a roughly 10 MiB config.
    static let maximumConfigurationBytes = 32 * 1024 * 1024
    static let maximumManifestBytes = 4_194_304
    /// NVFP4 prefill runs a larger compute chunk; its four-stream residual is
    /// authenticated in bounded records, with the whole array priced separately.
    static let prefillChunkTokens = 2048
    /// A rank that is not ready this long after it started is gone: parallel
    /// verification and the payload load with room to spare (both measured
    /// under five minutes for the Studio's 40 layers).
    static let startupSeconds = 420

    static let all: [Self] = [
        .init(model: .glm53Flash, profileID: "registered_glm53_flash_greedy_generation_v1",
            repository: GLM5NextArtifactPin.repository, revision: GLM5NextArtifactPin.revision,
            configurationSHA256: GLM5NextArtifactPin.configurationSHA256,
            manifestSHA256: "daee0b1bef9258ae0d8ed98b7a489586f2eb8453453302be057b12008d249649",
            artifactSHA256: GLM5NextArtifactPin.artifactSHA256,
            inventorySHA256: GLM5NextArtifactPin.inventorySHA256,
            manifestBytes: GLM5NextArtifactPin.manifestBytes, manifestFileCount: GLM5NextArtifactPin.manifestFileCount,
            layers: 45, hidden: 4096, vocabulary: 154_880, declaredContextTokens: 1_048_576,
            storage: .nvfp4Hybrid, executionPolicy: .serving,
            supportedPrefillSchedules: [.serial], supportedGenerationModes: [.pipeline, .tensorParallel]),
    ]

    static func specification(runtimeModelID: String) throws -> Self {
        guard let model = GLM5NextRegisteredModel(rawValue: runtimeModelID),
              let value = all.first(where: { $0.model == model }) else {
            throw ProbeError("Model ID is not a registered GLM resident model")
        }
        return value
    }

    /// The registered model whose pinned configuration these bytes are.
    static func specification(configuration: Data) throws -> Self {
        guard (1...maximumConfigurationBytes).contains(configuration.count) else {
            throw ProbeError("Configuration is not a registered GLM resident model's")
        }
        let digest = sha256(configuration)
        guard let value = all.first(where: { $0.configurationSHA256 == digest }) else {
            throw ProbeError("Configuration is not a registered GLM resident model's")
        }
        return value
    }

    static func handles(configuration: Data) -> Bool { (try? specification(configuration: configuration)) != nil }

    /// The request bounds: the protocol's, cut to the declared context.
    func contextLimits() throws -> QwenResidentContextLimits {
        try QwenResidentContextLimits(declaredContextTokens: declaredContextTokens,
            prefillChunkTokens: Self.prefillChunkTokens)
    }

    func profile(imageCandidate: Bool = false) throws -> QwenLayerStageGenerationProfile {
        let limits = try contextLimits()
        return try .init(identifier: imageCandidate ? ClusterGLMImageCandidate.profileID : profileID, vocabularySize: vocabulary, hiddenSize: hidden,
            activationDType: "bfloat16", maximumPromptTokens: limits.maximumPromptTokens,
            maximumChunkTokens: limits.maximumChunkTokens, maximumOutputTokens: limits.maximumOutputTokens,
            maximumContextTokens: limits.maximumContextTokens, residualStreams: 4)
    }

    /// The exact manifest of this row: its own digest, aggregate and the
    /// configuration file it lists. Returns the runtime files the verified
    /// loader reads (configuration, index and every shard).
    func runtimeFiles(manifest: Data) throws -> [String: GLM5NextArtifactIdentity.File] {
        guard (1...Self.maximumManifestBytes).contains(manifest.count), sha256(manifest) == manifestSHA256 else {
            throw ProbeError("Manifest is not the registered GLM model's")
        }
        let declared = try JSONDecoder().decode(CheckpointManifest.self, from: manifest)
        guard declared.aggregate_sha256 == artifactSHA256, declared.file_count == manifestFileCount,
              declared.files.count == manifestFileCount, declared.total_size_bytes == manifestBytes,
              Set(declared.files.map(\.path)).count == manifestFileCount,
              declared.files.first(where: { $0.path == "config.json" })?.sha256 == configurationSHA256 else {
            throw ProbeError("Pinned registered GLM manifest semantics differ")
        }
        var files: [String: GLM5NextArtifactIdentity.File] = [:]
        for entry in declared.files where entry.path == "config.json" || entry.path.hasSuffix(".safetensors")
            || entry.path == "model.safetensors.index.json" {
            files[entry.path] = .init(bytes: entry.size_bytes, sha256: entry.sha256)
        }
        guard files["model.safetensors.index.json"] != nil, files.count >= 3 else {
            throw ProbeError("Registered GLM manifest lacks its index or shards")
        }
        return files
    }

    /// The descriptor of one cut of this row, from the artifact's own bytes.
    /// `requestScope` (the single-Mac reference only): limits of exactly one
    /// request's prompt, chunk and outputs instead of the row's serving scope.
    /// The Plan does not depend on the limits, so both describe the same stages.
    func descriptor(configuration: Data, manifest: Data, cut: Int,
                    requestScope: (prompt: Int, chunk: Int, output: Int)? = nil, includesVision: Bool = false) throws -> GLM5NextResidentDescriptor {
        guard sha256(configuration) == configurationSHA256, supportedCuts.contains(cut) else {
            throw ProbeError("GLM descriptor requires the registered configuration and one of its cuts")
        }
        let limits = try contextLimits()
        let prompt = requestScope?.prompt ?? limits.maximumPromptTokens
        let chunk = requestScope?.chunk ?? limits.maximumChunkTokens
        let output = requestScope?.output ?? limits.maximumOutputTokens
        let context = requestScope.map { $0.prompt + $0.output + 1 } ?? limits.maximumContextTokens
        guard prompt <= limits.maximumPromptTokens, output <= limits.maximumOutputTokens,
              (1...limits.maximumChunkTokens).contains(chunk), context <= limits.maximumContextTokens else {
            throw ProbeError("GLM request scope exceeds the registered row's limits")
        }
        return try GLM5NextResidentDescriptor(modelID: model.rawValue,
            artifactIdentity: .init(repository: repository, revision: revision, files: runtimeFiles(manifest: manifest)),
            artifactAggregateSHA256: artifactSHA256, configurationBytes: configuration, cut: cut,
            storage: storage, executionPolicy: executionPolicy, profileID: includesVision ? ClusterGLMImageCandidate.profileID : profileID,
            maximumPromptTokens: prompt, maximumChunkTokens: chunk,
            maximumOutputTokens: output, maximumContextTokens: context, includesVision: includesVision)
    }
}
