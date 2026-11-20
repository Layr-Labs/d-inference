import Foundation

func workerCanonicalData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

/// These limits bound a single serialized text request, not provider admission.
struct WorkerLimits: Encodable {
    let maxContextTokens: Int
    let maxOutputTokens = 4096
    let maxChunkSize = 32768
    let maxTimeoutSeconds = 300
    let maxRequestsPerEpoch = 4096
    let maxCapturedLogitValues = 1_048_576
    let maxLineBytes = 2_097_152
    let idleTimeoutSeconds: Int

    init(loaded: LoadedModel, idleTimeoutSeconds: Int) throws {
        guard let root = try JSONSerialization.jsonObject(with: loaded.configurationData) as? [String: Any] else {
            throw ProbeError("Worker model configuration must be an object")
        }
        let text = root["text_config"] as? [String: Any] ?? root
        let declared = try qwenPartitionInteger(text, "max_position_embeddings")
        maxContextTokens = min(declared, 32768)
        self.idleTimeoutSeconds = idleTimeoutSeconds
    }
}

/// The supervisor separately verifies the bundle and source artifact before launch.
/// A missing direct-load receipt is represented honestly by "none".
struct WorkerIdentity: Encodable {
    let model: String
    let configurationSHA256: String
    let parameterLayoutSHA256: String
    let partition: String
    let partitionPlanSHA256: String
    let attentionOutputPrecision: String
    let vocabularySize: Int
    let layerCount: Int
    let feedForwardKind: String
    let embeddingActivationDType: String
    let ffnScaleDTypes: [String]
    let syntheticWeights: Bool
    let syntheticDType: String
    let syntheticProfile: String
    let seed: String
    let bf16ConversionEnabled: Bool
    let verifiedAggregateSHA256: String
    let transport: String
    let tokenSelectionPolicy: String
    let textOnly = true
    let mtpEnabled = false

    init(loaded: LoadedModel, options: Options, collective: Collective?) {
        model = loaded.label
        configurationSHA256 = loaded.configHash
        parameterLayoutSHA256 = loaded.parameterLayoutSHA256
        partition = loaded.partitionPlan?.kind.rawValue ?? "none"
        partitionPlanSHA256 = loaded.partitionPlan?.fingerprint ?? "none"
        attentionOutputPrecision = options.attentionOutputPrecision.rawValue
        vocabularySize = loaded.vocabularySize
        layerCount = loaded.layerCount
        feedForwardKind = loaded.feedForwardKind
        embeddingActivationDType = loaded.embeddingActivationDType
        ffnScaleDTypes = loaded.ffnScaleDTypes
        syntheticWeights = options.synthetic
        syntheticDType = options.synthetic ? options.syntheticDType : "none"
        syntheticProfile = options.synthetic ? options.syntheticProfile : "none"
        seed = String(options.seed)
        bf16ConversionEnabled = loaded.bf16ConversionEnabled
        verifiedAggregateSHA256 = loaded.directShardLoad?.verifiedAggregateSHA256 ?? "none"
        transport = collective?.transportLabel ?? "none"
        tokenSelectionPolicy = collective == nil ? "local-greedy" : "rank0-greedy"
    }
}

struct WorkerReady: Encodable {
    let version = 1, type = "ready"
    let epoch: String
    let rank: Int
    let worldSize: Int
    let pid: Int
    let modelLoadID: String
    let modelLoadCount = 1
    let identity: WorkerIdentity
    let identitySHA256: String
    let limits: WorkerLimits
}

struct WorkerAccepted: Encodable {
    let version = 1, type = "accepted"
    let epoch: String
    let rank: Int
    let sequence: Int
    let requestID: String
    let requestSHA256: String
    let modelLoadID: String
}

struct WorkerToken: Encodable {
    let version = 1, type = "token"
    let epoch: String
    let rank: Int
    let sequence: Int
    let requestID: String
    let step: Int
    let token: Int
}

struct WorkerCompleted: Encodable {
    let version = 1, type = "completed"
    let epoch: String
    let rank: Int
    let sequence: Int
    let requestID: String
    let requestSHA256: String
    let modelLoadID: String
    let result: RunResult
    let logits: [[Float]]?
}

struct WorkerStopped: Encodable {
    let version = 1, type = "stopped"
    let epoch: String
    let rank: Int
    let sequence: Int
}
