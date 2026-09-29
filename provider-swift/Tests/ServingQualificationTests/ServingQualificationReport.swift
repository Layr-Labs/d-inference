import Foundation
import MLXLMCommon

@testable import ProviderCore

struct ServingQualificationJob: Codable, Sendable {
    let modelID: String
    let modelPath: String
    let artifactSHA256: String
    let outputPath: String
    let promptLengths: [Int]
    let outputTokens: Int
    let width: Int
    let schedulerMaxConcurrentRequests: Int?
    let servingPolicy: Bool?
    let iterations: Int
    let mixedPrefillTokenCap: Int?
    let staggerMilliseconds: Int
    let reused: Bool
    let toolHistory: Bool
    let partition: String
    let runID: String
    let kvBackend: String
}

/// Numeric timings, hashes, and configuration only; never prompt/output text.
struct ServingQualificationRow: Codable, Sendable {
    let requestID: String
    let workloadSHA256: String
    let promptTokens: Int
    let requestedOutputTokens: Int
    let completionTokens: Int
    let firstContentMs: Double?
    let contentArrivalMs: [Double]
    let elapsedMs: Double
    let outputSHA256: String
    let cachedTokens: Int
    let profile: InferenceProfile
    let failure: String?
}

struct ServingQualificationTrial: Codable, Sendable {
    let iteration: Int
    let promptTarget: Int
    let rows: [ServingQualificationRow]
    let forwardShapes: CBv2ForwardShapeSnapshot
    let mtpActive: Bool
    let mtpRounds: Int
    let mtpProposed: Int
    let mtpAccepted: Int
    let peakMemoryBytes: Int
    let activeMemoryBytes: Int
    let thermalState: Int
    let lowPowerMode: Bool
    let retired: Bool
}

struct ServingQualificationRun: Codable, Sendable {
    let schemaVersion: Int
    let job: ServingQualificationJob
    let providerVersion: String
    let runtimeRevision: String
    let promptContractID: String
    let actualKVBackend: String
    let deadlineRuntimeConfiguration: DeadlineRuntimeConfiguration?
    let configuredContextTokens: Int
    let chipName: String
    let gpuCores: Int
    let memoryBytes: UInt64
    let mtp: ServingMTPConfiguration?
    let trials: [ServingQualificationTrial]
    let complete: Bool
    // This collector alone does not establish the full release matrix,
    // per-step mixed-prefill tails, accounting correctness, or confidence.
    let qualified: Bool
}
