import Foundation

/// Opt-in cap-0/cap-1 scheduler policy evaluation.
///
/// This report can show whether FCFS meets its measurement criteria and whether
/// one model-family run came from the signed packaged candidate. It never
/// certifies the global FCFS release policy; representative non-Qwen evidence
/// remains external to the Qwen matrix.
public struct SchedulerPrefillDecisionReport: Codable, Sendable {
    public static let currentSchemaVersion = 3
    public static let minimumLiveIterations = 10

    public enum Mode: String, Codable, Sendable {
        case deterministicScheduler = "deterministic_scheduler"
        case liveModel = "live_model"
    }

    public enum EvidenceClass: String, Codable, Sendable {
        case schedulerSimulation = "scheduler_simulation"
        case unsignedLocalHarness = "unsigned_local_harness"
        case signedCandidateModelFamily = "signed_candidate_model_family"
    }

    public struct Configuration: Codable, Sendable {
        public let maxConcurrentRequests: Int
        public let maxBatchedTokensPerStep: Int
        public let prefillChunkTokens: Int
        public let soloPrefillStripeTokens: Int
        /// Non-nil only for the normalized deterministic clock.
        public let modeledPromptTokensPerSecond: Double?
        public let timingBasis: String
    }

    /// Cryptographic identity of the selected checkpoint. `operatorModelID`
    /// is only a label; the hashes and parsed model type bind the evidence to
    /// the bytes that were actually loaded.
    public struct ModelIdentity: Codable, Sendable, Equatable {
        public let operatorModelID: String
        public let modelType: String
        public let architectures: [String]
        public let configSHA256: String
        public let snapshotAggregateSHA256: String
    }

    public struct HardwareIdentity: Codable, Sendable, Equatable {
        public let machineModel: String
        public let chipName: String
        public let memoryGB: UInt64
        public let gpuCores: UInt32
    }

    public struct PowerThermalPosture: Codable, Sendable, Equatable {
        public let powerSource: String
        public let batteryPercent: Int?
        public let lowPowerModeEnabled: Bool
        public let thermalState: String
    }

    public struct Reproducibility: Codable, Sendable, Equatable {
        public let startedAtUTC: String
        public let finishedAtUTC: String
        public let elapsedSeconds: Double
        public let sourceSHA: String?
        public let providerVersion: String
        public let executableName: String
        public let executableSHA256: String
        public let buildConfiguration: String
        public let operatingSystem: String
        public let hardware: HardwareIdentity
        public let postureAtStart: PowerThermalPosture
        public let postureAtEnd: PowerThermalPosture
    }

    public struct SignedArtifactIdentity: Codable, Sendable, Equatable {
        public let identifier: String
        public let teamID: String
        public let expectedProviderVersion: String
        public let observedProviderVersion: String
        public let expectedRegisteredBinarySHA256: String
        public let observedExecutableSHA256: String
    }

    public struct WorkloadRow: Codable, Sendable, Equatable {
        public let promptTokens: Int
        public let arrivalMs: Double

        public init(promptTokens: Int, arrivalMs: Double) {
            self.promptTokens = promptTokens
            self.arrivalMs = arrivalMs
        }
    }

    public struct Workload: Codable, Sendable, Equatable {
        public let name: String
        public let activeDecode: Bool
        public let rows: [WorkloadRow]

        public init(name: String, activeDecode: Bool = false, rows: [WorkloadRow]) {
            self.name = name
            self.activeDecode = activeDecode
            self.rows = rows
        }
    }

    public struct Row: Codable, Sendable {
        public let row: Int
        public let promptTokens: Int
        public let scheduledArrivalMs: Double
        /// Deterministic mode equals `scheduledArrivalMs`; live mode records
        /// when the task actually called `engine.submit`.
        public let submittedAtMs: Double
        public let firstTokenAtMs: Double
        public let ttftMs: Double
    }

    public struct PackedPrefill: Codable, Sendable {
        /// The scheduler emitted at least one same-length prompt cohort with
        /// B > 1, so a capable Qwen/cache pair can take the rectangular path.
        public let schedulerEligible: Bool
        /// Nil in deterministic mode: support is an engine/model/backend fact.
        public let modelAndCacheSupported: Bool?
        /// Nil in deterministic mode. Live mode reads execution counters.
        public let executed: Bool?
        public let eligibleGroups: Int
        public let eligibleRows: Int
        public let executedGroups: Int?
        public let executedRows: Int?
    }

    public struct Result: Codable, Sendable {
        public let workload: Workload
        public let iteration: Int
        /// Operator posture, not the resolved optional scheduler value:
        /// 0 is unlimited/interleaved; 1 is FCFS serialization.
        public let maxConcurrentPartialPrefills: Int
        public let rows: [Row]
        public let totalPromptTokens: Int
        public let makespanMs: Double
        public let aggregatePromptTokensPerSecond: Double
        public let schedulerSteps: Int?
        public let packedPrefill: PackedPrefill
        public let resolvedKVBackend: String?
    }

    public struct EvaluationThresholds: Codable, Sendable, Equatable {
        public let minimumLiveIterations: Int
        public let minimumThroughputRatio: Double
        public let minimumBurstMeanTTFTImprovement: Double
        public let firstContentBaseMs: Double
        public let firstContentPerPromptTokenMs: Double
        public let minimum8KBurstDeadlineHits: Int
    }

    public struct WorkloadComparison: Codable, Sendable, Equatable {
        public let workload: String
        public let cap0MedianAggregatePromptTokensPerSecond: Double
        public let cap1MedianAggregatePromptTokensPerSecond: Double
        public let throughputRatio: Double
        public let cap0MeanMedianTTFTMs: Double
        public let cap1MeanMedianTTFTMs: Double
        public let meanTTFTImprovement: Double
        public let cap0DeadlineHits: Int
        public let cap1DeadlineHits: Int
        public let cap1TTFTIsStrictStaircase: Bool
    }

    public struct EvaluationCheck: Codable, Sendable, Equatable {
        public let name: String
        public let passed: Bool
        public let detail: String
    }

    public enum EvaluationOutcome: String, Codable, Sendable {
        case pass
        case fail
        case insufficientEvidence = "insufficient_evidence"
    }

    public struct Evaluation: Codable, Sendable {
        public let outcome: EvaluationOutcome
        public let thresholds: EvaluationThresholds
        public let comparisons: [WorkloadComparison]
        public let checks: [EvaluationCheck]
        /// Always false. Even signed Qwen model-family evidence cannot certify
        /// the global policy without representative non-Qwen matrices.
        public let releaseCandidateCertified: Bool
        public let limitation: String
    }

    public let schemaVersion: Int
    public let mode: Mode
    public let evidenceClass: EvidenceClass
    public let signedArtifactIdentity: SignedArtifactIdentity?
    public let modelIdentity: ModelIdentity?
    public let reproducibility: Reproducibility?
    public let configuration: Configuration
    public let kvBackend: BenchmarkKVBackend?
    public let results: [Result]
    public let evaluation: Evaluation

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
