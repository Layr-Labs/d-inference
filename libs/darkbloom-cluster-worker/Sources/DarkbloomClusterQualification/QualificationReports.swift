import Foundation

/// What must be the same for two runs to be comparable. The first group is
/// known to every run; the optional group is derived by the native runtime and
/// is present when the producing run could observe it.
public struct QualificationIdentity: Codable, Equatable, Sendable {
    public var modelID: String
    public var profileID: String
    public var requestID: String
    public var promptTokenCount: Int
    public var promptTokenIDsSHA256: String
    public var chunkSize: Int
    public var outputCount: Int
    public var stopTokenIDs: [Int]
    public var stageCut: Int
    public var prefillSchedule: String
    public var artifactSHA256: String
    public var configurationSHA256: String
    public var planSHA256: String

    public var requestFingerprint: String?
    public var profileFingerprint: String?
    public var stageSHA256: [String]?
    public var storageCommitmentSHA256: String?
    public var arithmeticSHA256: String?

    public init(request: QualificationRequest, stageCut: Int, prefillSchedule: String,
                artifactSHA256: String, configurationSHA256: String, planSHA256: String) {
        modelID = request.modelID; profileID = request.profileID; requestID = request.requestID
        promptTokenCount = request.promptTokenIDs.count; promptTokenIDsSHA256 = request.promptTokenIDsSHA256
        chunkSize = request.chunkSize; outputCount = request.outputCount; stopTokenIDs = request.stopTokenIDs
        self.stageCut = stageCut; self.prefillSchedule = prefillSchedule
        self.artifactSHA256 = artifactSHA256; self.configurationSHA256 = configurationSHA256
        self.planSHA256 = planSHA256
    }

    /// Field names that differ, and optional fields only one side carries.
    public func differences(from other: Self, allowCutDifference: Bool = false) -> (differing: [String], notCompared: [String]) {
        var differing: [String] = [], skipped: [String] = []
        func required<T: Equatable>(_ name: String, _ a: T, _ b: T) { if a != b { differing.append(name) } }
        func optional<T: Equatable>(_ name: String, _ a: T?, _ b: T?) {
            guard let a, let b else { if a != nil || b != nil { skipped.append(name) }; return }
            if a != b { differing.append(name) }
        }
        required("modelID", modelID, other.modelID); required("profileID", profileID, other.profileID)
        required("requestID", requestID, other.requestID)
        required("promptTokenCount", promptTokenCount, other.promptTokenCount)
        required("promptTokenIDsSHA256", promptTokenIDsSHA256, other.promptTokenIDsSHA256)
        required("chunkSize", chunkSize, other.chunkSize); required("outputCount", outputCount, other.outputCount)
        required("stopTokenIDs", stopTokenIDs, other.stopTokenIDs)
        required("prefillSchedule", prefillSchedule, other.prefillSchedule)
        required("artifactSHA256", artifactSHA256, other.artifactSHA256)
        required("configurationSHA256", configurationSHA256, other.configurationSHA256)
        optional("requestFingerprint", requestFingerprint, other.requestFingerprint)
        optional("profileFingerprint", profileFingerprint, other.profileFingerprint)
        optional("arithmeticSHA256", arithmeticSHA256, other.arithmeticSHA256)
        // The cut selects the Plan, the stages and how storage is divided.
        if !(allowCutDifference && stageCut != other.stageCut) {
            required("stageCut", stageCut, other.stageCut); required("planSHA256", planSHA256, other.planSHA256)
            optional("stageSHA256", stageSHA256, other.stageSHA256)
            optional("storageCommitmentSHA256", storageCommitmentSHA256, other.storageCommitmentSHA256)
        }
        return (differing, skipped)
    }
}

/// One selected token with the largest logits of its row, descending.
public struct QualificationStep: Codable, Equatable, Sendable {
    public var ordinal: Int
    public var frameSequence: Int
    public var committedTokens: Int
    public var tokenID: Int
    public var topTokenIDs: [Int]
    public var topLogits: [Float]
    public var maximumTieCount: Int
    public var rowSHA256: String

    public init(ordinal: Int, frameSequence: Int, committedTokens: Int, tokenID: Int, topTokenIDs: [Int],
                topLogits: [Float], maximumTieCount: Int, rowSHA256: String) {
        self.ordinal = ordinal; self.frameSequence = frameSequence; self.committedTokens = committedTokens
        self.tokenID = tokenID; self.topTokenIDs = topTokenIDs; self.topLogits = topLogits
        self.maximumTieCount = maximumTieCount; self.rowSHA256 = rowSHA256
    }
}

/// The complete vocabulary row of the last selected token. `logicalBytesSHA256`
/// is over the row's native bytes; the values are its exact Float32 conversion.
public struct QualificationFinalLogits: Codable, Equatable, Sendable {
    public var shape: [Int]
    public var dtype: String
    public var byteCount: Int
    public var logicalBytesSHA256: String
    public var float32LittleEndianBase64: String

    public init(shape: [Int], dtype: String, byteCount: Int, logicalBytesSHA256: String, values: [Float]) {
        self.shape = shape; self.dtype = dtype; self.byteCount = byteCount
        self.logicalBytesSHA256 = logicalBytesSHA256
        var bytes = Data(capacity: values.count * 4)
        for value in values { withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) } }
        float32LittleEndianBase64 = bytes.base64EncodedString()
    }

    public func values() throws -> [Float] {
        guard let bytes = Data(base64Encoded: float32LittleEndianBase64), bytes.count % 4 == 0,
              bytes.count / 4 == shape.reduce(1, *) else {
            throw QualificationError("Final logits payload does not match its shape")
        }
        return bytes.withUnsafeBytes { raw in
            (0..<(bytes.count / 4)).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
    }
}

public struct QualificationStateEntry: Codable, Equatable, Sendable {
    public var globalLayerIndex: Int
    public var component: String
    public var shape: [Int]
    public var dtype: String
    public var byteCount: Int
    public var sha256: String

    public init(globalLayerIndex: Int, component: String, shape: [Int], dtype: String, byteCount: Int, sha256: String) {
        self.globalLayerIndex = globalLayerIndex; self.component = component; self.shape = shape
        self.dtype = dtype; self.byteCount = byteCount; self.sha256 = sha256
    }

    public var key: String { "\(globalLayerIndex)|\(component)" }

    /// The runtime's state-identity convention, so a pair's two disjoint stage
    /// captures join into the fingerprint a single-host run reports.
    public static func fingerprint(_ entries: [Self], committedTokens: Int) -> String {
        let sorted = entries.sorted { ($0.globalLayerIndex, $0.component) < ($1.globalLayerIndex, $1.component) }
        let lines = ["cbv2-owned-state-v1", "tokens=\(committedTokens)"]
            + sorted.map { "\($0.key)|\($0.shape)|\($0.dtype)|\($0.byteCount)|\($0.sha256)" }
        return QualificationHash.sha256(Data(lines.joined(separator: "\n").utf8))
    }
}

public struct QualificationEvidence: Codable, Equatable, Sendable {
    public var selectedTokenIDs: [Int]
    public var finishReason: String
    public var completedFrames: Int?
    public var committedTokens: Int?
    public var steps: [QualificationStep]?
    public var finalLogits: QualificationFinalLogits?
    public var stateEntries: [QualificationStateEntry]?
    public var stateSHA256: String?

    public init(selectedTokenIDs: [Int], finishReason: String, completedFrames: Int? = nil, committedTokens: Int? = nil,
                steps: [QualificationStep]? = nil, finalLogits: QualificationFinalLogits? = nil,
                stateEntries: [QualificationStateEntry]? = nil, stateSHA256: String? = nil) {
        self.selectedTokenIDs = selectedTokenIDs; self.finishReason = finishReason
        self.completedFrames = completedFrames; self.committedTokens = committedTokens; self.steps = steps
        self.finalLogits = finalLogits; self.stateEntries = stateEntries; self.stateSHA256 = stateSHA256
    }
}

/// A role and what kind of Mac filled it. Never a host name, address or user.
public struct QualificationHost: Codable, Equatable, Sendable {
    public var role: String
    public var chip: String?
    public var operatingSystem: String?

    public init(role: String, chip: String? = nil, operatingSystem: String? = nil) {
        self.role = role; self.chip = chip; self.operatingSystem = operatingSystem
    }

    public static func local(role: String) -> Self {
        var size = 0
        var chip: String?
        if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 1 {
            var bytes = [CChar](repeating: 0, count: size)
            if sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 {
                chip = String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return .init(role: role, chip: chip,
            operatingSystem: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
    }
}

public struct ReferenceTiming: Codable, Equatable, Sendable {
    public var stageLoadSeconds: [Double]
    public var prefillSeconds: Double
    public var prefillTokensPerSecond: Double
    public var decodeSeconds: Double
    public var decodeTokensPerSecond: Double?
    public var requestWallSeconds: Double
    public var totalSeconds: Double
    public var note: String

    public init(stageLoadSeconds: [Double], prefillSeconds: Double, prefillTokensPerSecond: Double,
                decodeSeconds: Double, decodeTokensPerSecond: Double?, requestWallSeconds: Double,
                totalSeconds: Double, note: String) {
        self.stageLoadSeconds = stageLoadSeconds; self.prefillSeconds = prefillSeconds
        self.prefillTokensPerSecond = prefillTokensPerSecond; self.decodeSeconds = decodeSeconds
        self.decodeTokensPerSecond = decodeTokensPerSecond; self.requestWallSeconds = requestWallSeconds
        self.totalSeconds = totalSeconds; self.note = note
    }
}

public struct ReferenceMemory: Codable, Equatable, Sendable {
    public var activeBytesBefore: Int
    public var activeBytesLoaded: Int
    public var peakBytes: Int
    public var activeBytesAfterRelease: Int
    public var cacheBytesAfterRelease: Int
    public var loadedTensorBytes: [Int]
    public var stageModelsReleased: [Bool]

    public init(activeBytesBefore: Int, activeBytesLoaded: Int, peakBytes: Int, activeBytesAfterRelease: Int,
                cacheBytesAfterRelease: Int, loadedTensorBytes: [Int], stageModelsReleased: [Bool]) {
        self.activeBytesBefore = activeBytesBefore; self.activeBytesLoaded = activeBytesLoaded
        self.peakBytes = peakBytes; self.activeBytesAfterRelease = activeBytesAfterRelease
        self.cacheBytesAfterRelease = cacheBytesAfterRelease; self.loadedTensorBytes = loadedTensorBytes
        self.stageModelsReleased = stageModelsReleased
    }
}

public struct ReferenceReport: Codable, Equatable, Sendable {
    public static let currentSchema = "darkbloom_cluster_reference_report_v1"
    public var schema: String
    public var kind: String
    public var createdUTC: String
    public var identity: QualificationIdentity
    public var evidence: QualificationEvidence
    public var host: QualificationHost
    public var binarySHA256: String?
    public var metallibSHA256: String?
    public var timing: ReferenceTiming
    public var memory: ReferenceMemory
    public var promptSource: QualificationPromptSource
    public var decodedOutput: String?

    public init(identity: QualificationIdentity, evidence: QualificationEvidence, host: QualificationHost,
                binarySHA256: String?, metallibSHA256: String?, timing: ReferenceTiming, memory: ReferenceMemory,
                promptSource: QualificationPromptSource, decodedOutput: String?) {
        schema = Self.currentSchema; kind = "singleHostStagedReference"
        createdUTC = QualificationReportFiles.timestamp()
        self.identity = identity; self.evidence = evidence; self.host = host
        self.binarySHA256 = binarySHA256; self.metallibSHA256 = metallibSHA256
        self.timing = timing; self.memory = memory; self.promptSource = promptSource; self.decodedOutput = decodedOutput
    }
}

/// One rank of a pair run, by role. `signalsSentByDriver` is a constant: the
/// driver has no code path that signals a worker.
public struct PairRankReport: Codable, Equatable, Sendable {
    public var role: String
    public var rank: Int
    public var chip: String?
    public var operatingSystem: String?
    public var workerSHA256: String?
    public var metallibSHA256: String?
    public var launched = false
    public var readyObserved = false
    public var readySeconds: Double?
    public var requestCapacityBytes: Int?
    public var admitted: Bool?
    public var refusal: String?
    public var events: [String] = []
    public var shutdownCommandSent = false
    public var shutdownCompleteObserved = false
    public var exitObserved = false
    public var exitStatus: Int32?
    public var exitSignal: Int32?
    public var signalsSentByDriver = 0
    public var workerProcessesLeft: Int?
    public var evidenceCollected = false
    public var evidenceSelectedTokenIDs: [Int]?
    public var diagnostics: String?

    public init(role: String, rank: Int) { self.role = role; self.rank = rank }
}

public struct PairTiming: Codable, Equatable, Sendable {
    public var startupSeconds: Double?
    public var admissionSeconds: Double?
    public var firstTokenSeconds: Double?
    public var prefillTokensPerSecond: Double?
    public var decodeSeconds: Double?
    public var decodeTokensPerSecond: Double?
    public var shutdownSeconds: Double?
    public var note: String

    public init(note: String) { self.note = note }
}

public struct PairReport: Codable, Equatable, Sendable {
    public static let currentSchema = "darkbloom_cluster_pair_report_v1"
    public var schema: String
    public var kind: String
    public var createdUTC: String
    /// `completed`, `refused` (nothing ran, or the reservation was refused), `failed`,
    /// or `preflight` (both sides inspected and found consistent; nothing launched).
    public var outcome: String
    public var failure: String?
    public var identity: QualificationIdentity?
    public var evidence: QualificationEvidence?
    public var ranks: [PairRankReport]
    public var workerHashesIdentical: Bool?
    public var metallibHashesIdentical: Bool?
    public var recording: Bool
    /// Rank 0's committed-token stream against each rank's recorded history.
    public var ranksAgreeOnTokens: Bool?
    public var bothExitsObserved: Bool
    public var noWorkerProcessLeft: Bool?
    public var progressTimeoutMilliseconds: Int?
    public var timing: PairTiming
    public var promptSource: QualificationPromptSource
    public var decodedOutput: String?

    public init(outcome: String, failure: String?, identity: QualificationIdentity?, evidence: QualificationEvidence?,
                ranks: [PairRankReport], workerHashesIdentical: Bool?, metallibHashesIdentical: Bool?, recording: Bool,
                ranksAgreeOnTokens: Bool?, bothExitsObserved: Bool, noWorkerProcessLeft: Bool?,
                progressTimeoutMilliseconds: Int?, timing: PairTiming, promptSource: QualificationPromptSource,
                decodedOutput: String?) {
        schema = Self.currentSchema; kind = "twoRankPair"; createdUTC = QualificationReportFiles.timestamp()
        self.outcome = outcome; self.failure = failure; self.identity = identity; self.evidence = evidence
        self.ranks = ranks; self.workerHashesIdentical = workerHashesIdentical
        self.metallibHashesIdentical = metallibHashesIdentical; self.recording = recording
        self.ranksAgreeOnTokens = ranksAgreeOnTokens; self.bothExitsObserved = bothExitsObserved
        self.noWorkerProcessLeft = noWorkerProcessLeft; self.progressTimeoutMilliseconds = progressTimeoutMilliseconds
        self.timing = timing; self.promptSource = promptSource; self.decodedOutput = decodedOutput
    }
}

/// Either kind of report, reduced to what a comparison reads.
public struct QualificationSubject: Equatable, Sendable {
    public var label: String
    public var identity: QualificationIdentity
    public var evidence: QualificationEvidence

    public init(label: String, identity: QualificationIdentity, evidence: QualificationEvidence) {
        self.label = label; self.identity = identity; self.evidence = evidence
    }
}

public enum QualificationReportFiles {
    public static let maximumBytes = 32 * 1024 * 1024

    public static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(10)
        return data
    }

    /// Reads a reference report or a completed pair report.
    public static func subject(_ url: URL) throws -> QualificationSubject {
        let data = try QualificationFiles.read(url, maximumBytes: maximumBytes)
        struct Header: Decodable { let schema: String }
        switch try JSONDecoder().decode(Header.self, from: data).schema {
        case ReferenceReport.currentSchema:
            let report = try JSONDecoder().decode(ReferenceReport.self, from: data)
            return .init(label: "single-host reference (\(report.host.chip ?? "unknown chip"))",
                         identity: report.identity, evidence: report.evidence)
        case PairReport.currentSchema:
            let report = try JSONDecoder().decode(PairReport.self, from: data)
            guard report.outcome == "completed", let identity = report.identity, let evidence = report.evidence else {
                throw QualificationError("Pair report \(url.lastPathComponent) records outcome '\(report.outcome)' and has no evidence to compare")
            }
            let chips = report.ranks.map { $0.chip ?? "unknown chip" }.joined(separator: " + ")
            return .init(label: "two-rank pair (\(chips))", identity: identity, evidence: evidence)
        default:
            throw QualificationError("\(url.lastPathComponent) is neither a reference report nor a pair report")
        }
    }
}
