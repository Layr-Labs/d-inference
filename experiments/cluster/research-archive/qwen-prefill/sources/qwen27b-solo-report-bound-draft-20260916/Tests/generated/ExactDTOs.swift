import Foundation


struct QwenResidentSoloKernelEligibility: Encodable, Decodable {
    let gatedDeltaLayers: Int
    let fusedProjectionLayers: Int
    let warmupDispatch: QwenGatedDeltaWarmupObservation
    let configuredQueryBlockSize: Int
    let queryBlockDispatchIndependentlyCounted = false
    let measuredRequestDispatchObservationEnabled = false
    let optimizedAgainstAllPossibleSoloPolicies = false
}

struct QwenResidentSoloCohortRequest: Encodable, Decodable {
    let ordinal: Int
    let isWarmup: Bool
    let execution: QwenResidentSoloRequestResult
}

struct QwenResidentSoloCohortReport: Encodable, Decodable {
    let kind = "qwen_resident_solo_generation_report"
    let schemaVersion = 1
    let completed = true
    let verifiedFullModelLoads = 1
    let warmupCount = 1
    let measuredCount: Int
    let freshRequestsAdmitted: Int
    let modelReleased = true
    let allRequestStateRetired = true
    let prefixReuse = false
    let mtpEnabled = false
    let allocatorPolicy = "disable_freed_buffer_cache_v1"
    let unusedDiagnosticAllowanceStillReserved = true
    let independentNumericalComparisonPerformed = false
    let physicalOrPerformanceQualificationEstablished = false
    let externalTTFTMeasured = false
    let source: QwenLongPrefillReferenceSource
    let sourceLoad: VerifiedQwenDiagnosticReceipt
    let expectedTokenFileSHA256: String
    let kernelEligibility: QwenResidentSoloKernelEligibility
    let requests: [QwenResidentSoloCohortRequest]
    let resources: QwenFullGenerationReferenceResourceReceipt
    let memory: [QwenStageMemoryObservation]
    let runtime: QwenDenseStageLoadRuntimeObservation
}

struct QwenResidentSoloTiming: Encodable, Decodable {
    let clock = "DispatchTime.uptimeNanoseconds.same_process"
    let requestStartNanoseconds: UInt64
    let selectedTokenNanoseconds: [UInt64]
    let retiredNanoseconds: UInt64
    let prefillSeconds: Double
    let decodeSeconds: Double
    let prefillTokensPerSecond: Double
    let decodeTokensPerSecond: Double
    let includesLoading = false
    let includesSourceAndResourceAdmission = false
    let includesFreshStateConstruction = true
    let includesPerForwardOwnershipValidation = true
    let includesDiagnosticRowOrStateCapture = false
    let includesTransport = false
    let externalTTFTMeasured = false
}

struct QwenResidentSoloRequestResult: Encodable, Decodable {
    let requestID: UUID
    let requestFingerprint: String
    let selectedTokenIDs: [Int]
    let selectedTokenIDsSHA256: String
    let completedFrames: Int
    let committedTokens: Int
    let timing: QwenResidentSoloTiming
    let promptCount = 8192
    let chunkSize = 512
    let requestedOutputCount = 128
    let finishReason = "length"
    let expectedTokenSequenceMatched = true
    let allRequestStateRetired = true
    let modelRemainsResident = true
    let prefixReuse = false
    let mtpEnabled = false
    let fullVocabularyRowsCaptured = false
    let stateSnapshotsCaptured = false
    let independentFullRowStateComparisonPerformed = false
}

struct QwenLongPrefillReferenceSource: Encodable, Decodable {
    let artifactAggregateSHA256: String, sourceConfigurationSHA256: String
    let sourceParameterLayoutSHA256: String, planSHA256: String
    let arithmeticEnvironmentSHA256: String
    let bf16ConversionEnabled: Bool, embeddingActivationDType: String
    let sourceModelTensorBytes: Int, layerCount: Int, vocabularySize: Int
}

struct VerifiedQwenDiagnosticReceipt: Codable {
    let schemaVersion: Int
    let verifiedAggregateSHA256: String
    let configurationSHA256: String
    let sourceModelTensorBytes: Int
    let loadedTensorBytes: Int
    let largestHostTensorBytes: Int
    let tensorCount: Int
    let sourceTensorCount: Int
    let parameterLayoutSHA256: String
    let bf16ConversionEnabled: Bool
}

struct QwenFullGenerationReferenceResourceReceipt: Encodable, Decodable {
    let policy = "qwen_full_generation_reference_resources_v1"
    let budget: QwenFullGenerationReferenceBudget
    let authorizedTensorCount: Int
    let observationCount: Int
    let minimumActualFreeBytes: Int
    let maximumObservedActiveBytes: Int
    let requestResourceAdmissionPerformed: Bool
    let actualAllocatorBoundsUsed = true
    let reclaimableUsedForAdmission = false
    let wholeProcessPeakBoundEstablished = false
}

struct QwenFullGenerationReferenceBudget: Encodable, Decodable {
    let profileFingerprint: String
    let requestFingerprint: String
    let planFingerprint: String
    let sourceNames: [String]
    let sourceByteCounts: [Int]
    let allocationBounds: [Int]
    let largestHostTensorBytes: Int
    let payloadReadScratchBytes = CheckpointAlignedReadPlan.maximumScratchAllocationBytes
    let stateBytes: Int
    let fusionBytes: Int
    let capturedRowsCPUBytes: Int
    let captureNativeBytes: Int
    let requestReservedBytes: Int
    let wholeProcessPeakBoundEstablished = false
}

struct QwenStageMemoryObservation: Encodable, Decodable {
    let phase: String
    let activeMLXBytes: Int
    let cachedMLXBytes: Int
    let peakMLXBytesSinceProcessStart: Int
}

struct QwenDenseStageLoadRuntimeObservation: Encodable, Decodable {
    let executableName: String?, mainBundleName: String, bundleIdentifier: String?
    let executablePath: String?, mainBundlePath: String, mainBundleResourcePath: String?
    let processID: Int32, operatingSystemVersion: String
    let deviceArchitecture: String, deviceMemoryBytes: Int, maximumBufferBytes: Int
    let recommendedWorkingSetBytes: UInt64
    let binaryOrBundleHashVerifiedByNative = false, providerEligibilityEstablished = false
    let recommendedWorkingSetUsedForAdmission = false
}

public struct QwenGatedDeltaWarmupObservation: Encodable, Decodable {
    public let nativePrefillCalls: Int
    public let nativeDecodeCalls: Int
    public let operationsFallbackCalls: Int
    public let invalidGeometryCalls: Int
}

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}


func canonicalJSONData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}



enum QwenResidentSoloOutput {
    static let progressMaximumBytes = 128 * 1024
    static let finalMaximumBytes = 512 * 1024

    static func encode<T: Encodable>(_ value: T, maximumBytes: Int) throws -> Data {
        var data = try canonicalJSONData(value)
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ProbeError("Resident solo output exceeds its bound")
        }
        data.append(10)
        return data
    }
}

enum CheckpointAlignedReadPlan { static let maximumScratchAllocationBytes = 8404992 }
