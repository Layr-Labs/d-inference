struct Report: Encodable {
    let schemaVersion = 7
    let mode: String
    let modelFamily: String
    let model: String
    let configurationSHA256: String
    let rank: Int
    let worldSize: Int
    let promptSource: String
    let teacherForced: Bool
    let chunkSize: Int
    let loadSeconds: Double
    let syntheticWeights: Bool
    let mtpEnabled = false
    let shardedFFNs: Int
    let seed: UInt64
    let timestamp: String
    let promptSHA256: String
    let teacherSHA256: String?
    let embeddingActivationDType: String
    let ffnScaleDTypes: [String]
    let parameterLayoutSHA256: String
    let bf16ConversionEnabled: Bool
    let throughputMeasurementValid: Bool
    let transport: String
    let correctnessOnly: Bool
    let directShardLoad: DirectShardLoadReceipt?
    let partition: String
    let partitionPlanSHA256: String?
    let tokenSelectionPolicy: String
    let vocabularySize: Int
    let syntheticDType: String?
    let syntheticProfile: String?
    let feedForwardKind: String
    let attentionOutputPrecision: String
    let ffnBranchPrecision: String
    let routingTraceEnabled: Bool?
    let routingReplayEnabled: Bool?
    let gemmaDiagnosticScheduleEnabled: Bool?
    let gemmaBoundaryTraceEnabled: Bool?
    let decodeScheduling = "synchronous-per-token"
    let prefillDefinition = "all prompt tokens through first generated token"
    let partitionStorage: PartitionStorageCommitment?
    let runs: [RunResult]
}
