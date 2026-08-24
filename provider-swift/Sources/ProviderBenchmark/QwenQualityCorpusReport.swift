import Foundation

/// Machine-readable output of one fixed-weight Qwen quality-corpus run.
public struct QwenQualityCorpusReport: Codable, Sendable {
    public static let currentSchemaVersion = 1
    public static let benchmarkName = "qwen-quality-corpus"
    public static let tokenChecksumAlgorithmName = "fnv1a64-le-i64-v1"
    public static let maximumReportBytes = 128 * 1024 * 1024

    public struct Run: Codable, Equatable, Sendable {
        public let label: String
        public let createdAtUTC: String

        public init(label: String, createdAtUTC: String) {
            self.label = label
            self.createdAtUTC = createdAtUTC
        }
    }

    public struct Model: Codable, Equatable, Sendable {
        public let id: String
        public let path: String
        /// Canonical `WeightHasher` digest over weights plus tokenizer/config
        /// integrity files. Baseline/candidate comparison requires equality.
        public let artifactSHA256: String
        public let modelType: String
        public let architecture: String?
        public let maximumContextTokens: Int?

        public init(
            id: String,
            path: String,
            artifactSHA256: String,
            modelType: String,
            architecture: String?,
            maximumContextTokens: Int?
        ) {
            self.id = id
            self.path = path
            self.artifactSHA256 = artifactSHA256
            self.modelType = modelType
            self.architecture = architecture
            self.maximumContextTokens = maximumContextTokens
        }
    }

    public struct Corpus: Codable, Equatable, Sendable {
        public let id: String
        public let version: String
        public let path: String
        public let sha256: String
        public let caseCount: Int
        public let license: String
        public let provenance: String

        public init(
            id: String,
            version: String,
            path: String,
            sha256: String,
            caseCount: Int,
            license: String,
            provenance: String
        ) {
            self.id = id
            self.version = version
            self.path = path
            self.sha256 = sha256
            self.caseCount = caseCount
            self.license = license
            self.provenance = provenance
        }
    }

    public struct Hardware: Codable, Equatable, Sendable {
        public let machineModel: String
        public let chipName: String
        public let memoryGB: UInt64
        public let gpuCores: UInt32

        public init(
            machineModel: String,
            chipName: String,
            memoryGB: UInt64,
            gpuCores: UInt32
        ) {
            self.machineModel = machineModel
            self.chipName = chipName
            self.memoryGB = memoryGB
            self.gpuCores = gpuCores
        }
    }

    public struct Engine: Codable, Equatable, Sendable {
        public let factory: String
        public let kvBackendSelection: String
        public let resolvedKVBackend: String
        public let maxConcurrentRequests: Int
        public let requestsExecutedSequentially: Bool
        public let prefixCacheEnabled: Bool
        public let warmupPerformed: Bool
        /// Allowlisted prefill-policy variables captured before model load.
        public let policyEnvironment: [String: String]

        public init(
            factory: String,
            kvBackendSelection: String,
            resolvedKVBackend: String,
            maxConcurrentRequests: Int,
            requestsExecutedSequentially: Bool,
            prefixCacheEnabled: Bool,
            warmupPerformed: Bool,
            policyEnvironment: [String: String]
        ) {
            self.factory = factory
            self.kvBackendSelection = kvBackendSelection
            self.resolvedKVBackend = resolvedKVBackend
            self.maxConcurrentRequests = maxConcurrentRequests
            self.requestsExecutedSequentially = requestsExecutedSequentially
            self.prefixCacheEnabled = prefixCacheEnabled
            self.warmupPerformed = warmupPerformed
            self.policyEnvironment = policyEnvironment
        }
    }

    public struct Generation: Codable, Equatable, Sendable {
        public let temperature: Float
        public let topP: Float
        public let topK: Int
        public let maximumTokens: Int
        public let minimumRequiredTokens: Int
        /// Fixed-length means no stop token/string is supplied to CBv2. This
        /// makes every case produce the same >=32-token comparison window.
        public let stopPolicy: String

        public init(
            temperature: Float,
            topP: Float,
            topK: Int,
            maximumTokens: Int,
            minimumRequiredTokens: Int,
            stopPolicy: String
        ) {
            self.temperature = temperature
            self.topP = topP
            self.topK = topK
            self.maximumTokens = maximumTokens
            self.minimumRequiredTokens = minimumRequiredTokens
            self.stopPolicy = stopPolicy
        }
    }

    public struct CaseResult: Codable, Equatable, Sendable {
        public let id: String
        public let category: String
        public let prompt: String
        public let promptTokenCount: Int
        /// Submit-to-first-sampled-token wall time. It includes scheduler
        /// admission, prefill, final-logit sampling, and event delivery.
        public let timeToFirstTokenMs: Double
        /// `(promptTokenCount - 1) / timeToFirstToken`; diagnostic only.
        public let estimatedPrefillTokensPerSecond: Double
        public let totalTimeMs: Double
        public let generatedTokenCount: Int
        public let generatedTokenIDs: [Int]
        public let tokenChecksum: String
        /// Authoritative text concatenated from CBv2 delta events.
        public let text: String
        public let finishReason: String

        public init(
            id: String,
            category: String,
            prompt: String,
            promptTokenCount: Int,
            timeToFirstTokenMs: Double,
            estimatedPrefillTokensPerSecond: Double,
            totalTimeMs: Double,
            generatedTokenCount: Int,
            generatedTokenIDs: [Int],
            tokenChecksum: String,
            text: String,
            finishReason: String
        ) {
            self.id = id
            self.category = category
            self.prompt = prompt
            self.promptTokenCount = promptTokenCount
            self.timeToFirstTokenMs = timeToFirstTokenMs
            self.estimatedPrefillTokensPerSecond = estimatedPrefillTokensPerSecond
            self.totalTimeMs = totalTimeMs
            self.generatedTokenCount = generatedTokenCount
            self.generatedTokenIDs = generatedTokenIDs
            self.tokenChecksum = tokenChecksum
            self.text = text
            self.finishReason = finishReason
        }
    }

    public let schemaVersion: Int
    public let benchmark: String
    public let tokenChecksumAlgorithm: String
    public let run: Run
    public let model: Model
    public let corpus: Corpus
    public let hardware: Hardware
    public let engine: Engine
    public let generation: Generation
    public let cases: [CaseResult]
    public let comparison: QwenQualityCorpusComparison?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        benchmark: String = benchmarkName,
        tokenChecksumAlgorithm: String = tokenChecksumAlgorithmName,
        run: Run,
        model: Model,
        corpus: Corpus,
        hardware: Hardware,
        engine: Engine,
        generation: Generation,
        cases: [CaseResult],
        comparison: QwenQualityCorpusComparison? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.benchmark = benchmark
        self.tokenChecksumAlgorithm = tokenChecksumAlgorithm
        self.run = run
        self.model = model
        self.corpus = corpus
        self.hardware = hardware
        self.engine = engine
        self.generation = generation
        self.cases = cases
        self.comparison = comparison
    }

    public func addingComparison(
        _ value: QwenQualityCorpusComparison
    ) -> QwenQualityCorpusReport {
        QwenQualityCorpusReport(
            schemaVersion: schemaVersion,
            benchmark: benchmark,
            tokenChecksumAlgorithm: tokenChecksumAlgorithm,
            run: run,
            model: model,
            corpus: corpus,
            hardware: hardware,
            engine: engine,
            generation: generation,
            cases: cases,
            comparison: value)
    }

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func load(from url: URL) throws -> QwenQualityCorpusReport {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw QwenQualityCorpusReportError.notRegularFile(url.path)
        }
        guard let size = values.fileSize, size > 0, size <= maximumReportBytes else {
            throw QwenQualityCorpusReportError.invalidFileSize(
                actual: values.fileSize ?? 0, maximum: maximumReportBytes)
        }
        let report: QwenQualityCorpusReport
        do {
            report = try JSONDecoder().decode(
                QwenQualityCorpusReport.self,
                from: Data(contentsOf: url, options: [.mappedIfSafe]))
        } catch {
            throw QwenQualityCorpusReportError.invalidJSON(String(describing: error))
        }
        try report.validate()
        return report
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw QwenQualityCorpusReportError.unsupportedSchemaVersion(schemaVersion)
        }
        guard benchmark == Self.benchmarkName else {
            throw QwenQualityCorpusReportError.wrongBenchmark(benchmark)
        }
        guard tokenChecksumAlgorithm == Self.tokenChecksumAlgorithmName else {
            throw QwenQualityCorpusReportError.wrongChecksumAlgorithm(
                tokenChecksumAlgorithm)
        }
        guard (QwenQualityCorpusExecutor.minimumGenerationTokens
            ... QwenQualityCorpusExecutor.maximumGenerationTokens)
            .contains(generation.maximumTokens),
              generation.minimumRequiredTokens
                == QwenQualityCorpusExecutor.minimumGenerationTokens,
              generation.temperature == 0,
              generation.topP == 1,
              generation.topK == 0,
              generation.stopPolicy == "fixed-length-no-stop-tokens"
        else {
            throw QwenQualityCorpusReportError.invalidGenerationWindow
        }
        guard engine.factory == "EngineV2Factory.makeProductionBuild", // pragma: allowlist secret
              engine.maxConcurrentRequests == 1,
              engine.requestsExecutedSequentially,
              !engine.prefixCacheEnabled
        else {
            throw QwenQualityCorpusReportError.invalidEngineContract
        }
        guard corpus.caseCount == cases.count,
              (1 ... QwenQualityCorpusLoader.maximumCases).contains(cases.count)
        else {
            throw QwenQualityCorpusReportError.caseCountMismatch(
                expected: corpus.caseCount, actual: cases.count)
        }
        guard isSHA256(model.artifactSHA256), isSHA256(corpus.sha256) else {
            throw QwenQualityCorpusReportError.invalidDigest
        }
        var seen: Set<String> = []
        for entry in cases {
            guard seen.insert(entry.id).inserted else {
                throw QwenQualityCorpusReportError.duplicateCaseID(entry.id)
            }
            guard entry.promptTokenCount > 0,
                  entry.generatedTokenCount == generation.maximumTokens,
                  entry.generatedTokenIDs.count == entry.generatedTokenCount,
                  entry.generatedTokenIDs.allSatisfy({ $0 >= 0 }),
                  entry.finishReason == "length",
                  entry.timeToFirstTokenMs.isFinite,
                  entry.timeToFirstTokenMs >= 0,
                  entry.estimatedPrefillTokensPerSecond.isFinite,
                  entry.estimatedPrefillTokensPerSecond >= 0,
                  entry.totalTimeMs.isFinite,
                  entry.totalTimeMs >= entry.timeToFirstTokenMs,
                  entry.tokenChecksum
                    == ArrivalPrefillAccounting.tokenChecksum(entry.generatedTokenIDs)
            else {
                throw QwenQualityCorpusReportError.invalidCase(entry.id)
            }
        }
    }

    private func isSHA256(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 64 && bytes.allSatisfy {
            (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
        }
    }
}

public enum QwenQualityCorpusReportError: Error, Equatable, CustomStringConvertible {
    case notRegularFile(String)
    case invalidFileSize(actual: Int, maximum: Int)
    case invalidJSON(String)
    case unsupportedSchemaVersion(Int)
    case wrongBenchmark(String)
    case wrongChecksumAlgorithm(String)
    case invalidGenerationWindow
    case invalidEngineContract
    case caseCountMismatch(expected: Int, actual: Int)
    case invalidDigest
    case duplicateCaseID(String)
    case invalidCase(String)

    public var description: String {
        switch self {
        case .notRegularFile(let path):
            return "quality report is not a regular file: \(path)"
        case .invalidFileSize(let actual, let maximum):
            return "quality report size \(actual) is outside 1...\(maximum) bytes"
        case .invalidJSON(let message):
            return "quality report JSON is invalid: \(message)"
        case .unsupportedSchemaVersion(let version):
            return "quality report schemaVersion \(version) is unsupported"
        case .wrongBenchmark(let value):
            return "quality report benchmark '\(value)' is not "
                + "'\(QwenQualityCorpusReport.benchmarkName)'"
        case .wrongChecksumAlgorithm(let value):
            return "quality report checksum algorithm '\(value)' is unsupported"
        case .invalidGenerationWindow:
            return "quality report does not describe a valid >=32-token generation window"
        case .invalidEngineContract:
            return "quality report does not describe the sequential serving EngineV2 contract"
        case .caseCountMismatch(let expected, let actual):
            return "quality report declares \(expected) cases but contains \(actual)"
        case .invalidDigest:
            return "quality report has an invalid model or corpus SHA-256 digest"
        case .duplicateCaseID(let id):
            return "quality report contains duplicate case id '\(id)'"
        case .invalidCase(let id):
            return "quality report case '\(id)' has inconsistent output or timing fields"
        }
    }
}
