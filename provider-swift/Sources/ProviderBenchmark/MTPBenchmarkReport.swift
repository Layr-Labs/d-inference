import Darwin
import Foundation

public enum MTPBenchmarkBuildConfiguration: String, Codable, Sendable {
    case debug
    case release

    public static var current: MTPBenchmarkBuildConfiguration {
        #if DEBUG
        .debug
        #else
        .release
        #endif
    }
}

public enum MTPBenchmarkPurpose: String, Codable, Sendable {
    /// Fixed-length, no-stop correctness stress. Performance fields are
    /// deliberately omitted because this is not production serving behavior.
    case rawParityStress = "raw_parity_stress"
    /// Production-shaped correctness using the target's exact stop-token set.
    case productionCorrectness = "production_correctness"
    /// Production-shaped performance using the target's exact stop-token set.
    case productionPerformance = "production_performance"

    public var performanceEligible: Bool { self == .productionPerformance }
}

/// Declares whether requested fixed/adaptive cases must exercise MTP or must
/// prove a specific fail-open safety gate. Inactive validation is never
/// inferred from the machine or the engine result.
public struct MTPBenchmarkMTPExpectation: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case active
        case expectedInactive = "expected_inactive"
    }

    /// Backward-compatible validator for reports created before the
    /// chip-independent serial target verifier replaced the M5 denylist.
    public static let legacyM5HardwareSafetyGate = MTPBenchmarkMTPExpectation(
        kind: .expectedInactive,
        allowedInactiveReasonPrefixes: [
            "rectangular MTP verification is disabled on Apple M5"
        ])

    public let kind: Kind
    public let allowedInactiveReasonValues: [String]
    public let allowedInactiveReasonPrefixes: [String]

    public static let active = MTPBenchmarkMTPExpectation(kind: .active)

    public static func expectedInactive(
        allowedReasonValues: [String] = [],
        allowedReasonPrefixes: [String] = []
    ) -> MTPBenchmarkMTPExpectation {
        MTPBenchmarkMTPExpectation(
            kind: .expectedInactive,
            allowedInactiveReasonValues: allowedReasonValues,
            allowedInactiveReasonPrefixes: allowedReasonPrefixes)
    }

    public init(
        kind: Kind,
        allowedInactiveReasonValues: [String] = [],
        allowedInactiveReasonPrefixes: [String] = []
    ) {
        self.kind = kind
        self.allowedInactiveReasonValues = allowedInactiveReasonValues.sorted()
        self.allowedInactiveReasonPrefixes = allowedInactiveReasonPrefixes.sorted()
    }

    public var expectsInactive: Bool { kind == .expectedInactive }

    public func matchesInactiveReason(_ reason: String?) -> Bool {
        guard let reason, !reason.isEmpty else { return false }
        return allowedInactiveReasonValues.contains(reason)
            || allowedInactiveReasonPrefixes.contains { reason.hasPrefix($0) }
    }

    var isWellFormed: Bool {
        let values = allowedInactiveReasonValues + allowedInactiveReasonPrefixes
        switch kind {
        case .active:
            return values.isEmpty
        case .expectedInactive:
            return !values.isEmpty && values.allSatisfy { !$0.isEmpty }
        }
    }
}

public struct MTPBenchmarkStopPolicy: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case rawFixedLengthNoStop = "raw_fixed_length_no_stop"
        case productionTargetEOS = "production_target_eos"
    }

    public let kind: Kind
    let stopTokenIDs: [Int]

    public var configuredTokenCount: Int { stopTokenIDs.count }

    public static let rawFixedLength = MTPBenchmarkStopPolicy(
        kind: .rawFixedLengthNoStop, stopTokenIDs: [])

    public static func production(tokenIDs: Set<Int>) -> MTPBenchmarkStopPolicy {
        MTPBenchmarkStopPolicy(
            kind: .productionTargetEOS, stopTokenIDs: tokenIDs.sorted())
    }

    public init(kind: Kind, stopTokenIDs: [Int]) {
        self.kind = kind
        self.stopTokenIDs = stopTokenIDs
    }
}

/// Persisted stop-policy evidence deliberately records only cardinality. The
/// runtime IDs remain in memory and are validated against every stop event.
public struct MTPBenchmarkStopPolicySummary: Codable, Equatable, Sendable {
    public let kind: MTPBenchmarkStopPolicy.Kind
    public let configuredTokenCount: Int

    init(_ policy: MTPBenchmarkStopPolicy) {
        kind = policy.kind
        configuredTokenCount = policy.configuredTokenCount
    }
}

public struct MTPBenchmarkMode: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case targetOnly = "target_only"
        case fixed
        case adaptive
    }

    public let kind: Kind
    /// Target verification width L. Fixed modes cover L=1...8, where draft
    /// depth k=L-1. Nil for target-only and adaptive modes.
    public let verificationWidth: Int?

    public static let targetOnly = MTPBenchmarkMode(kind: .targetOnly)
    public static let adaptive = MTPBenchmarkMode(kind: .adaptive)

    public static func fixed(verificationWidth: Int) throws -> MTPBenchmarkMode {
        guard (1...8).contains(verificationWidth) else {
            throw MTPBenchmarkError.invalidVerificationWidth(verificationWidth)
        }
        return MTPBenchmarkMode(kind: .fixed, verificationWidth: verificationWidth)
    }

    public init(kind: Kind, verificationWidth: Int? = nil) {
        self.kind = kind
        self.verificationWidth = verificationWidth
    }

    public var requestsMTP: Bool { kind != .targetOnly }
    public var fixedDraftTokens: Int? {
        guard kind == .fixed, let verificationWidth else { return nil }
        return verificationWidth - 1
    }

    public var label: String {
        switch kind {
        case .targetOnly: return "target-only"
        case .fixed: return "fixed-L\(verificationWidth ?? -1)"
        case .adaptive: return "adaptive"
        }
    }
}

public struct MTPBenchmarkArtifactFacts: Codable, Equatable, Sendable {
    public struct Quantization: Codable, Equatable, Sendable {
        public let bits: Int?
        public let groupSize: Int?
        public let mode: String?
        public let perLayerOverridesByBits: [String: Int]

        public init(
            bits: Int?,
            groupSize: Int?,
            mode: String?,
            perLayerOverridesByBits: [String: Int] = [:]
        ) {
            self.bits = bits
            self.groupSize = groupSize
            self.mode = mode
            self.perLayerOverridesByBits = perLayerOverridesByBits
        }
    }

    public struct WeightFile: Codable, Equatable, Sendable {
        public enum IdentityKind: String, Codable, Sendable {
            case hfBlobSHA256 = "hf_blob_sha256"
            case hfBlobGitSHA1 = "hf_blob_git_sha1"
            case sha256
        }

        public let name: String
        public let sizeBytes: Int64
        public let identityKind: IdentityKind
        public let contentIdentity: String

        public init(
            name: String,
            sizeBytes: Int64,
            identityKind: IdentityKind = .sha256,
            contentIdentity: String = ""
        ) {
            self.name = name
            self.sizeBytes = sizeBytes
            self.identityKind = identityKind
            self.contentIdentity = contentIdentity
        }
    }

    public let modelID: String
    public let resolvedPath: String
    public let revision: String?
    public let modelType: String?
    public let architecture: String?
    public let dtype: String?
    public let quantization: Quantization?
    public let configSizeBytes: Int64
    public let configSHA256: String
    public let weightFiles: [WeightFile]
    public let artifactFingerprint: String

    public var weightFileCount: Int { weightFiles.count }
    public var weightBytes: Int64 { weightFiles.reduce(0) { $0 + $1.sizeBytes } }
    public var artifactBytes: Int64 {
        let (total, overflow) = configSizeBytes.addingReportingOverflow(weightBytes)
        return overflow ? Int64.max : total
    }
    public var hasVerifiableProvenance: Bool {
        Self.isSHA256(configSHA256)
            && Self.isSHA256(artifactFingerprint)
            && !weightFiles.isEmpty
            && weightFiles.allSatisfy {
                !$0.contentIdentity.isEmpty
                    && ($0.identityKind != .sha256 || Self.isSHA256($0.contentIdentity))
            }
    }

    public init(
        modelID: String,
        resolvedPath: String,
        revision: String?,
        modelType: String?,
        architecture: String?,
        dtype: String?,
        quantization: Quantization?,
        configSizeBytes: Int64 = 0,
        configSHA256: String = "",
        weightFiles: [WeightFile],
        artifactFingerprint: String = ""
    ) {
        self.modelID = modelID
        self.resolvedPath = resolvedPath
        self.revision = revision
        self.modelType = modelType
        self.architecture = architecture
        self.dtype = dtype
        self.quantization = quantization
        self.configSizeBytes = configSizeBytes
        self.configSHA256 = configSHA256
        self.weightFiles = weightFiles
        self.artifactFingerprint = artifactFingerprint
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

public struct MTPBenchmarkHardware: Codable, Sendable {
    public let machineModel: String
    public let chipName: String
    public let chipFamily: String
    public let chipTier: String
    public let memoryGB: UInt64
    public let gpuCores: UInt32
    public let memoryBandwidthGBps: UInt32

    public init(
        machineModel: String,
        chipName: String,
        chipFamily: String,
        chipTier: String,
        memoryGB: UInt64,
        gpuCores: UInt32,
        memoryBandwidthGBps: UInt32
    ) {
        self.machineModel = machineModel
        self.chipName = chipName
        self.chipFamily = chipFamily
        self.chipTier = chipTier
        self.memoryGB = memoryGB
        self.gpuCores = gpuCores
        self.memoryBandwidthGBps = memoryBandwidthGBps
    }
}

/// Stable benchmark-side projection of the engine's lock-safe MTP metrics.
/// Optional timing/controller fields remain nil until the production engine
/// exposes them; the report never invents values.
public struct MTPBenchmarkMetrics: Codable, Sendable {
    public struct CostInput: Codable, Sendable {
        public let decodeRowBucket: Int
        public let draftDepth: Int
        public let sampleCount: Int
        public let ewmaRoundWallTimeNanos: UInt64?
        public let totalRoundWallTimeNanos: UInt64?

        public init(
            decodeRowBucket: Int,
            draftDepth: Int,
            sampleCount: Int,
            ewmaRoundWallTimeNanos: UInt64? = nil,
            totalRoundWallTimeNanos: UInt64? = nil
        ) {
            self.decodeRowBucket = decodeRowBucket
            self.draftDepth = draftDepth
            self.sampleCount = sampleCount
            self.ewmaRoundWallTimeNanos = ewmaRoundWallTimeNanos
            self.totalRoundWallTimeNanos = totalRoundWallTimeNanos
        }

        fileprivate func withoutPerformanceMeasurements() -> CostInput {
            CostInput(
                decodeRowBucket: decodeRowBucket,
                draftDepth: draftDepth,
                sampleCount: sampleCount)
        }
    }

    public let active: Bool
    public let verificationMode: String?
    public let maxAutomaticRectangularTokens: Int?
    public let rectangularVerificationRounds: Int?
    public let serialVerificationRounds: Int?
    public let inactiveReason: String?
    public let selectedDepth: Int?
    public let decodeRowBucket: Int?
    public let rounds: Int
    public let seedRows: Int
    public let proposedTokens: Int
    public let acceptedDraftTokens: Int
    public let committedTokens: Int
    public let acceptanceByPosition: [Int]
    public let conditionalAcceptance: [Double]
    public let skippedRows: [String: Int]
    public let depthSelections: [String: Int]
    public let controllerFallbacks: [String: Int]
    public let costInputs: [CostInput]
    public let totalRoundWallTimeNanos: UInt64?
    public let assistantTimeNanos: UInt64?
    public let targetVerifyTimeNanos: UInt64?

    public init(
        active: Bool,
        verificationMode: String? = nil,
        maxAutomaticRectangularTokens: Int? = nil,
        rectangularVerificationRounds: Int? = nil,
        serialVerificationRounds: Int? = nil,
        inactiveReason: String? = nil,
        selectedDepth: Int? = nil,
        decodeRowBucket: Int? = nil,
        rounds: Int = 0,
        seedRows: Int = 0,
        proposedTokens: Int = 0,
        acceptedDraftTokens: Int = 0,
        committedTokens: Int = 0,
        acceptanceByPosition: [Int] = [],
        conditionalAcceptance: [Double] = [],
        skippedRows: [String: Int] = [:],
        depthSelections: [String: Int] = [:],
        controllerFallbacks: [String: Int] = [:],
        costInputs: [CostInput] = [],
        totalRoundWallTimeNanos: UInt64? = nil,
        assistantTimeNanos: UInt64? = nil,
        targetVerifyTimeNanos: UInt64? = nil
    ) {
        self.active = active
        self.verificationMode = verificationMode
        self.maxAutomaticRectangularTokens = maxAutomaticRectangularTokens
        self.rectangularVerificationRounds = rectangularVerificationRounds
        self.serialVerificationRounds = serialVerificationRounds
        self.inactiveReason = inactiveReason
        self.selectedDepth = selectedDepth
        self.decodeRowBucket = decodeRowBucket
        self.rounds = rounds
        self.seedRows = seedRows
        self.proposedTokens = proposedTokens
        self.acceptedDraftTokens = acceptedDraftTokens
        self.committedTokens = committedTokens
        self.acceptanceByPosition = acceptanceByPosition
        self.conditionalAcceptance = conditionalAcceptance
        self.skippedRows = skippedRows
        self.depthSelections = depthSelections
        self.controllerFallbacks = controllerFallbacks
        self.costInputs = costInputs
        self.totalRoundWallTimeNanos = totalRoundWallTimeNanos
        self.assistantTimeNanos = assistantTimeNanos
        self.targetVerifyTimeNanos = targetVerifyTimeNanos
    }

    public static let inactive = MTPBenchmarkMetrics(active: false)

    fileprivate func withoutPerformanceMeasurements() -> MTPBenchmarkMetrics {
        MTPBenchmarkMetrics(
            active: active,
            verificationMode: verificationMode,
            maxAutomaticRectangularTokens: maxAutomaticRectangularTokens,
            rectangularVerificationRounds: rectangularVerificationRounds,
            serialVerificationRounds: serialVerificationRounds,
            inactiveReason: inactiveReason,
            selectedDepth: selectedDepth,
            decodeRowBucket: decodeRowBucket,
            rounds: rounds,
            seedRows: seedRows,
            proposedTokens: proposedTokens,
            acceptedDraftTokens: acceptedDraftTokens,
            committedTokens: committedTokens,
            acceptanceByPosition: acceptanceByPosition,
            conditionalAcceptance: conditionalAcceptance,
            skippedRows: skippedRows,
            depthSelections: depthSelections,
            controllerFallbacks: controllerFallbacks,
            costInputs: costInputs.map { $0.withoutPerformanceMeasurements() })
    }
}

public struct MTPBenchmarkRowResult: Codable, Sendable {
    public let promptName: String
    public let tokenCount: Int
    public let opaqueTokenDigest: String
    /// Median production-performance timings. These are nil for raw parity
    /// and production-correctness reports so they cannot be quoted as TPS.
    public let timeToFirstTokenMs: Double?
    public let interTokenLatencyMs: Double?
    public let decodeTokensPerSecond: Double?
    /// Submission to last token. Terminal-event delivery is excluded.
    public let lastTokenLatencyMs: Double?
    public let finishReason: String

    public init(
        promptName: String,
        tokenCount: Int,
        opaqueTokenDigest: String,
        timeToFirstTokenMs: Double?,
        interTokenLatencyMs: Double?,
        decodeTokensPerSecond: Double?,
        lastTokenLatencyMs: Double?,
        finishReason: String
    ) {
        self.promptName = promptName
        self.tokenCount = tokenCount
        self.opaqueTokenDigest = opaqueTokenDigest
        self.timeToFirstTokenMs = timeToFirstTokenMs
        self.interTokenLatencyMs = interTokenLatencyMs
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.lastTokenLatencyMs = lastTokenLatencyMs
        self.finishReason = finishReason
    }

    fileprivate func withoutPerformanceMeasurements() -> MTPBenchmarkRowResult {
        MTPBenchmarkRowResult(
            promptName: promptName,
            tokenCount: tokenCount,
            opaqueTokenDigest: opaqueTokenDigest,
            timeToFirstTokenMs: nil,
            interTokenLatencyMs: nil,
            decodeTokensPerSecond: nil,
            lastTokenLatencyMs: nil,
            finishReason: finishReason)
    }
}

public struct MTPBenchmarkCaseResult: Codable, Sendable {
    public let mode: MTPBenchmarkMode
    public let batchSize: Int
    public let measurementRepetitions: Int
    /// Median over repetitions, using sum(N-1) decode intervals over one
    /// common earliest-first-token to latest-last-token batch interval.
    /// Nil unless the entire report is production-performance eligible.
    public let medianAggregateDecodeTokensPerSecond: Double?
    public let tokenParity: Bool
    public let parityMismatchRows: [Int]
    public let rows: [MTPBenchmarkRowResult]
    public let metrics: MTPBenchmarkMetrics

    public init(
        mode: MTPBenchmarkMode,
        batchSize: Int,
        measurementRepetitions: Int,
        medianAggregateDecodeTokensPerSecond: Double?,
        tokenParity: Bool,
        parityMismatchRows: [Int],
        rows: [MTPBenchmarkRowResult],
        metrics: MTPBenchmarkMetrics
    ) {
        self.mode = mode
        self.batchSize = batchSize
        self.measurementRepetitions = measurementRepetitions
        self.medianAggregateDecodeTokensPerSecond = medianAggregateDecodeTokensPerSecond
        self.tokenParity = tokenParity
        self.parityMismatchRows = parityMismatchRows
        self.rows = rows
        self.metrics = metrics
    }

    fileprivate func withoutPerformanceMeasurements() -> MTPBenchmarkCaseResult {
        MTPBenchmarkCaseResult(
            mode: mode,
            batchSize: batchSize,
            measurementRepetitions: measurementRepetitions,
            medianAggregateDecodeTokensPerSecond: nil,
            tokenParity: tokenParity,
            parityMismatchRows: parityMismatchRows,
            rows: rows.map { $0.withoutPerformanceMeasurements() },
            metrics: metrics.withoutPerformanceMeasurements())
    }
}

public enum MTPBenchmarkGateStatus: String, Codable, Sendable {
    case covered
    case notRun = "not_run"
    case notImplemented = "not_implemented"
    case notInThisReport = "not_in_this_report"
}

/// Honest scope labels for gates that a short cached-model matrix does not
/// implement. These fields intentionally prevent a QAT smoke from standing in
/// for quantization, fixture, modality, or long-context coverage.
public struct MTPBenchmarkCoverage: Codable, Sendable {
    public let qat4BitShortContextSmoke: MTPBenchmarkGateStatus
    public let eightBitTargetPairing: MTPBenchmarkGateStatus
    public let bf16AssistantPairing: MTPBenchmarkGateStatus
    public let officialTensorFixtures: MTPBenchmarkGateStatus
    public let toolTemplateDecodeParity: MTPBenchmarkGateStatus
    public let structuredOutput: MTPBenchmarkGateStatus
    public let imagePrefill: MTPBenchmarkGateStatus
    public let videoPrefill: MTPBenchmarkGateStatus
    public let longSlidingAndPrefixContexts: MTPBenchmarkGateStatus
    public let opaqueTokenEvidence: MTPBenchmarkGateStatus
    public let productionServingStopPolicy: MTPBenchmarkGateStatus
    public let artifactProvenanceAndDrift: MTPBenchmarkGateStatus
    public let conservativeAssistantSizing: MTPBenchmarkGateStatus
    public let scopeNote: String

    public static func shortContextMatrix(
        target: MTPBenchmarkArtifactFacts,
        assistant: MTPBenchmarkArtifactFacts,
        purpose: MTPBenchmarkPurpose = .rawParityStress
    ) -> MTPBenchmarkCoverage {
        let targetName = target.modelID.lowercased()
        let assistantName = assistant.modelID.lowercased()
        let isQAT4 = targetName.contains("qat") && assistantName.contains("qat")
            && effectiveQuantizationBits(target) == 4
            && effectiveQuantizationBits(assistant) == 4
        let isEightBitTarget = target.modelType == "gemma4"
            && effectiveQuantizationBits(target) == 8
        let normalizedAssistantDType = assistant.dtype?
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        let isBF16Assistant = assistant.modelType == "gemma4_assistant"
            && (normalizedAssistantDType == "bfloat16" || normalizedAssistantDType == "bf16")
            && assistant.quantization == nil
        let coveredPairings = [
            isEightBitTarget ? "8-bit target" : nil,
            isBF16Assistant ? "BF16 assistant" : nil,
        ].compactMap { $0 }
        let pairingNote = coveredPairings.isEmpty
            ? "No 8-bit-target or BF16-assistant pairing is represented."
            : "Artifact inspection identifies: \(coveredPairings.joined(separator: ", "))."
        return MTPBenchmarkCoverage(
            qat4BitShortContextSmoke: isQAT4 ? .covered : .notRun,
            eightBitTargetPairing: isEightBitTarget ? .covered : .notRun,
            bf16AssistantPairing: isBF16Assistant ? .covered : .notRun,
            officialTensorFixtures: .notImplemented,
            toolTemplateDecodeParity: .notInThisReport,
            structuredOutput: .notImplemented,
            imagePrefill: .notInThisReport,
            videoPrefill: .notImplemented,
            longSlidingAndPrefixContexts: .notImplemented,
            opaqueTokenEvidence: .covered,
            productionServingStopPolicy: purpose == .rawParityStress
                ? .notInThisReport : .covered,
            artifactProvenanceAndDrift:
                target.hasVerifiableProvenance && assistant.hasVerifiableProvenance
                    ? .covered : .notRun,
            conservativeAssistantSizing: .covered,
            scopeNote: "Short-context text matrix only. \(pairingNote) Generated token arrays are never persisted. Official-tensor, structured-output, video, and long/prefix-context gates are not implemented here.")
    }

    public init(
        qat4BitShortContextSmoke: MTPBenchmarkGateStatus,
        eightBitTargetPairing: MTPBenchmarkGateStatus,
        bf16AssistantPairing: MTPBenchmarkGateStatus,
        officialTensorFixtures: MTPBenchmarkGateStatus,
        toolTemplateDecodeParity: MTPBenchmarkGateStatus,
        structuredOutput: MTPBenchmarkGateStatus,
        imagePrefill: MTPBenchmarkGateStatus,
        videoPrefill: MTPBenchmarkGateStatus,
        longSlidingAndPrefixContexts: MTPBenchmarkGateStatus,
        opaqueTokenEvidence: MTPBenchmarkGateStatus,
        productionServingStopPolicy: MTPBenchmarkGateStatus,
        artifactProvenanceAndDrift: MTPBenchmarkGateStatus,
        conservativeAssistantSizing: MTPBenchmarkGateStatus,
        scopeNote: String
    ) {
        self.qat4BitShortContextSmoke = qat4BitShortContextSmoke
        self.eightBitTargetPairing = eightBitTargetPairing
        self.bf16AssistantPairing = bf16AssistantPairing
        self.officialTensorFixtures = officialTensorFixtures
        self.toolTemplateDecodeParity = toolTemplateDecodeParity
        self.structuredOutput = structuredOutput
        self.imagePrefill = imagePrefill
        self.videoPrefill = videoPrefill
        self.longSlidingAndPrefixContexts = longSlidingAndPrefixContexts
        self.opaqueTokenEvidence = opaqueTokenEvidence
        self.productionServingStopPolicy = productionServingStopPolicy
        self.artifactProvenanceAndDrift = artifactProvenanceAndDrift
        self.conservativeAssistantSizing = conservativeAssistantSizing
        self.scopeNote = scopeNote
    }

    private static func effectiveQuantizationBits(
        _ artifact: MTPBenchmarkArtifactFacts
    ) -> Int? {
        guard let quantization = artifact.quantization else { return nil }
        if let bits = quantization.bits { return bits }
        let overrideBits = Set(quantization.perLayerOverridesByBits.compactMap { key, count in
            count > 0 ? Int(key) : nil
        })
        return overrideBits.count == 1 ? overrideBits.first : nil
    }
}

public struct MTPBenchmarkReport: Codable, Sendable {
    public static let currentSchemaVersion = 5

    public let schemaVersion: Int
    public let runFingerprint: String
    public let buildConfiguration: MTPBenchmarkBuildConfiguration
    public let purpose: MTPBenchmarkPurpose
    public let mtpExpectation: MTPBenchmarkMTPExpectation
    public let stopPolicy: MTPBenchmarkStopPolicySummary
    public let startedAt: Date
    public let generatedAt: Date
    public let completedAt: Date?
    public let complete: Bool
    public let expectedCaseCount: Int
    public let target: MTPBenchmarkArtifactFacts
    public let assistant: MTPBenchmarkArtifactFacts
    public let hardware: MTPBenchmarkHardware
    public let maxTokensPerRow: Int
    public let warmupIterations: Int
    public let measurementRepetitions: Int
    public let modeOrderSeed: UInt64
    public let coverage: MTPBenchmarkCoverage
    public let elapsedMs: Double?
    public let cases: [MTPBenchmarkCaseResult]

    public static func buildBoundFingerprint(
        _ launchFingerprint: String,
        buildConfiguration: MTPBenchmarkBuildConfiguration,
        mtpExpectation: MTPBenchmarkMTPExpectation = .active
    ) -> String {
        "\(buildConfiguration.rawValue):\(mtpExpectation.kind.rawValue):\(launchFingerprint)"
    }

    public init(
        schemaVersion: Int = MTPBenchmarkReport.currentSchemaVersion,
        runFingerprint: String,
        buildConfiguration: MTPBenchmarkBuildConfiguration = .current,
        purpose: MTPBenchmarkPurpose,
        mtpExpectation: MTPBenchmarkMTPExpectation = .active,
        stopPolicy: MTPBenchmarkStopPolicy,
        startedAt: Date,
        generatedAt: Date = Date(),
        completedAt: Date?,
        complete: Bool,
        expectedCaseCount: Int,
        target: MTPBenchmarkArtifactFacts,
        assistant: MTPBenchmarkArtifactFacts,
        hardware: MTPBenchmarkHardware,
        maxTokensPerRow: Int,
        warmupIterations: Int,
        measurementRepetitions: Int,
        modeOrderSeed: UInt64,
        coverage: MTPBenchmarkCoverage,
        elapsedMs: Double?,
        cases: [MTPBenchmarkCaseResult]
    ) {
        self.schemaVersion = schemaVersion
        self.runFingerprint = Self.buildBoundFingerprint(
            runFingerprint,
            buildConfiguration: buildConfiguration,
            mtpExpectation: mtpExpectation)
        self.buildConfiguration = buildConfiguration
        self.purpose = purpose
        self.mtpExpectation = mtpExpectation
        self.stopPolicy = MTPBenchmarkStopPolicySummary(stopPolicy)
        self.startedAt = startedAt
        self.generatedAt = generatedAt
        self.completedAt = completedAt
        self.complete = complete
        self.expectedCaseCount = expectedCaseCount
        self.target = target
        self.assistant = assistant
        self.hardware = hardware
        self.maxTokensPerRow = maxTokensPerRow
        self.warmupIterations = warmupIterations
        self.measurementRepetitions = measurementRepetitions
        self.modeOrderSeed = modeOrderSeed
        self.coverage = coverage
        self.elapsedMs = purpose.performanceEligible ? elapsedMs : nil
        self.cases = purpose.performanceEligible
            ? cases
            : cases.map { $0.withoutPerformanceMeasurements() }
    }

    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func write(to destination: MTPBenchmarkReportDestination) throws {
        try destination.write(jsonData())
    }
}

/// Descriptor-relative destination for benchmark checkpoints. The directory is
/// opened once without following its final path component; every temporary
/// write and rename remains anchored to that descriptor even if the visible
/// directory path is replaced while the benchmark is running.
public final class MTPBenchmarkReportDestination: @unchecked Sendable {
    public let directoryURL: URL
    public let fileName: String

    private let directoryFileDescriptor: Int32
    private let directoryDevice: UInt64
    private let directoryInode: UInt64

    public var url: URL { directoryURL.appendingPathComponent(fileName) }

    public static func open(
        directoryURL: URL,
        fileName: String,
        expectedDevice: UInt64? = nil,
        expectedInode: UInt64? = nil
    ) throws -> MTPBenchmarkReportDestination {
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/")
        else {
            throw MTPBenchmarkError.unsafeReportDestination("invalid report filename")
        }
        let descriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw posixError("open benchmark report directory")
        }
        do {
            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0 else {
                throw posixError("stat benchmark report directory")
            }
            guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                throw MTPBenchmarkError.unsafeReportDestination(
                    "report parent is not a directory")
            }
            if expectedDevice != nil || expectedInode != nil {
                guard (metadata.st_mode & mode_t(0o777)) == mode_t(0o700),
                      metadata.st_uid == Darwin.geteuid()
                else {
                    throw MTPBenchmarkError.unsafeReportDestination(
                        "supervised report parent is not private and process-owned")
                }
            }
            let device = UInt64(metadata.st_dev)
            let inode = UInt64(metadata.st_ino)
            if let expectedDevice, expectedDevice != device {
                throw MTPBenchmarkError.unsafeReportDestination(
                    "report parent device changed")
            }
            if let expectedInode, expectedInode != inode {
                throw MTPBenchmarkError.unsafeReportDestination(
                    "report parent inode changed")
            }
            return MTPBenchmarkReportDestination(
                directoryURL: directoryURL.standardizedFileURL,
                fileName: fileName,
                directoryFileDescriptor: descriptor,
                directoryDevice: device,
                directoryInode: inode)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private init(
        directoryURL: URL,
        fileName: String,
        directoryFileDescriptor: Int32,
        directoryDevice: UInt64,
        directoryInode: UInt64
    ) {
        self.directoryURL = directoryURL
        self.fileName = fileName
        self.directoryFileDescriptor = directoryFileDescriptor
        self.directoryDevice = directoryDevice
        self.directoryInode = directoryInode
    }

    deinit {
        Darwin.close(directoryFileDescriptor)
    }

    fileprivate func write(_ data: Data) throws {
        try validateOpenDirectory()
        let temporaryName = ".\(fileName).\(UUID().uuidString).tmp"
        let descriptor = Darwin.openat(
            directoryFileDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw posixError("create benchmark checkpoint") }

        var temporaryMetadata = stat()
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(
                        descriptor,
                        bytes.baseAddress!.advanced(by: offset),
                        bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw posixError("write benchmark checkpoint") }
                    offset += count
                }
            }
            guard Darwin.fsync(descriptor) == 0 else {
                throw posixError("sync benchmark checkpoint")
            }
            guard Darwin.fstat(descriptor, &temporaryMetadata) == 0 else {
                throw posixError("stat benchmark checkpoint")
            }
            guard (temporaryMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
                throw MTPBenchmarkError.unsafeReportDestination(
                    "checkpoint temporary is not a regular file")
            }
        } catch {
            Darwin.close(descriptor)
            Darwin.unlinkat(directoryFileDescriptor, temporaryName, 0)
            throw error
        }
        Darwin.close(descriptor)

        guard Darwin.renameat(
            directoryFileDescriptor,
            temporaryName,
            directoryFileDescriptor,
            fileName) == 0
        else {
            Darwin.unlinkat(directoryFileDescriptor, temporaryName, 0)
            throw posixError("publish benchmark checkpoint")
        }

        let finalDescriptor = Darwin.openat(
            directoryFileDescriptor,
            fileName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard finalDescriptor >= 0 else {
            throw posixError("reopen benchmark checkpoint")
        }
        defer { Darwin.close(finalDescriptor) }
        var finalMetadata = stat()
        guard Darwin.fstat(finalDescriptor, &finalMetadata) == 0 else {
            throw posixError("stat published benchmark checkpoint")
        }
        guard (finalMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              finalMetadata.st_dev == temporaryMetadata.st_dev,
              finalMetadata.st_ino == temporaryMetadata.st_ino
        else {
            throw MTPBenchmarkError.unsafeReportDestination(
                "published checkpoint inode changed")
        }
        guard Darwin.fsync(directoryFileDescriptor) == 0 else {
            throw posixError("sync benchmark report directory")
        }
        try validateOpenDirectory()
    }

    private func validateOpenDirectory() throws {
        var metadata = stat()
        guard Darwin.fstat(directoryFileDescriptor, &metadata) == 0 else {
            throw posixError("stat open benchmark report directory")
        }
        guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              UInt64(metadata.st_dev) == directoryDevice,
              UInt64(metadata.st_ino) == directoryInode
        else {
            throw MTPBenchmarkError.unsafeReportDestination(
                "open report parent identity changed")
        }
    }
}

private func posixError(_ operation: String) -> NSError {
    NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(errno),
        userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"])
}

public enum MTPBenchmarkError: Error, CustomStringConvertible, Sendable {
    case invalidVerificationWidth(Int)
    case invalidBatchSize(Int)
    case invalidWarmupIterations(Int)
    case invalidMeasurementRepetitions(Int)
    case emptyPromptCorpus
    case missingTargetOnlyBaseline
    case invalidStopPolicy(String)
    case invalidMTPExpectation(String)
    case mtpRequestedButInactive(String)
    case productionMTPSeamUnavailable
    case missingTerminalEvent(row: Int)
    case unsuccessfulTerminal(row: Int, reason: String)
    case unexpectedTerminal(row: Int, condition: String)
    case emptyTokenStream(row: Int)
    case invalidTokenTimeline(String)
    case invalidMetrics(String)
    case inconsistentRepetition(String)
    case tokenParityMismatch(mode: String, batchSize: Int, rows: [Int])
    case invalidBuildConfiguration(String)
    case artifactIdentity(String)
    case artifactDrift(String)
    case unsafeReportDestination(String)
    case deadlineExceeded

    public var description: String {
        switch self {
        case .invalidVerificationWidth(let width):
            return "MTP verification width must be in 1...8, got \(width)"
        case .invalidBatchSize(let size):
            return "MTP benchmark batch size must be positive, got \(size)"
        case .invalidWarmupIterations(let count):
            return "MTP benchmark warmup iterations must be nonnegative, got \(count)"
        case .invalidMeasurementRepetitions(let count):
            return "MTP benchmark measurement repetitions must be positive, got \(count)"
        case .emptyPromptCorpus:
            return "MTP benchmark prompt corpus is empty"
        case .missingTargetOnlyBaseline:
            return "MTP benchmark modes must include a target-only parity baseline"
        case .invalidStopPolicy(let detail):
            return "invalid MTP benchmark stop policy: \(detail)"
        case .invalidMTPExpectation(let detail):
            return "invalid MTP benchmark activation expectation: \(detail)"
        case .mtpRequestedButInactive(let mode):
            return "MTP was requested for \(mode), but the production engine reported it inactive"
        case .productionMTPSeamUnavailable:
            return "production EngineV2 construction has not exposed the MTP drafter/config seam"
        case .missingTerminalEvent(let row):
            return "MTP benchmark row \(row) ended without a terminal event"
        case .unsuccessfulTerminal(let row, let reason):
            return "MTP benchmark row \(row) failed with terminal reason \(reason)"
        case .unexpectedTerminal(let row, let condition):
            return "MTP benchmark row \(row) violated \(condition)"
        case .emptyTokenStream(let row):
            return "MTP benchmark row \(row) completed without a sampled token"
        case .invalidTokenTimeline(let detail):
            return "invalid MTP benchmark token timeline: \(detail)"
        case .invalidMetrics(let detail):
            return "invalid MTP benchmark engine metrics: \(detail)"
        case .inconsistentRepetition(let detail):
            return "inconsistent MTP benchmark repetition: \(detail)"
        case .tokenParityMismatch(let mode, let batchSize, let rows):
            return "MTP token parity failed for \(mode), B=\(batchSize), rows=\(rows)"
        case .invalidBuildConfiguration(let detail):
            return "invalid MTP benchmark build configuration: \(detail)"
        case .artifactIdentity(let detail):
            return "invalid MTP benchmark artifact identity: \(detail)"
        case .artifactDrift(let label):
            return "MTP benchmark \(label) artifact changed during the run"
        case .unsafeReportDestination(let detail):
            return "unsafe MTP benchmark report destination: \(detail)"
        case .deadlineExceeded:
            return "MTP benchmark deadline exceeded"
        }
    }
}
