import Foundation

public enum KVQuantSuite: String, CaseIterable, Codable, Sendable {
    case performance = "perf"
    case memory
    case output
    case perplexity = "ppl"
    case logits
    case niah
    case capacity

    public var displayName: String {
        switch self {
        case .performance: "performance"
        case .memory: "memory"
        case .output: "output_smoke"
        case .perplexity: "perplexity"
        case .logits: "logits"
        case .niah: "needle_in_a_haystack"
        case .capacity: "capacity"
        }
    }
}

public enum KVQuantCandidateMode: String, CaseIterable, Codable, Sendable, CustomStringConvertible {
    case fp16KV = "fp16-kv"
    case bf16KV = "bf16-kv:start1024"
    case fullVBF16 = "full-v-bf16:start1024"
    case affine4 = "affine4:g64:start1024"
    case affine8 = "affine8:g64:start1024"
    case fullVAffine4 = "full-v-affine4:g64:start1024"
    case fullVTurbo4 = "full-v-turbo4:start1024"
    case fullKVTurbo4 = "full-kv-turbo4:start1024"
    case turbo4v2 = "turbo4v2:start1024"
    case k8v8g128 = "k8v8:g128"
    case k8v8g64 = "k8v8:g64"
    case k8v8g64Dequant = "k8v8:g64:dequant"
    case k6v6g64 = "k6v6:g64"
    case k6v6g64Dequant = "k6v6:g64:dequant"

    public var description: String { rawValue }

    public var label: String { rawValue }

    public var isReference: Bool { self == .fp16KV }

    public var bitWidth: Int? {
        switch self {
        case .fp16KV, .bf16KV, .fullVBF16: nil
        case .affine8, .k8v8g128, .k8v8g64, .k8v8g64Dequant: 8
        case .k6v6g64, .k6v6g64Dequant: 6
        case .affine4, .fullVAffine4, .fullVTurbo4, .fullKVTurbo4, .turbo4v2: 4
        }
    }

    public var groupSize: Int? {
        switch self {
        case .affine4, .affine8, .fullVAffine4, .k8v8g64, .k8v8g64Dequant, .k6v6g64, .k6v6g64Dequant: 64
        case .k8v8g128: 128
        case .fp16KV, .bf16KV, .fullVBF16, .fullVTurbo4, .fullKVTurbo4, .turbo4v2: nil
        }
    }

    public var startToken: Int? {
        switch self {
        case .fp16KV: nil
        case .bf16KV, .fullVBF16, .affine4, .affine8, .fullVAffine4, .fullVTurbo4, .fullKVTurbo4, .turbo4v2: 1024
        case .k8v8g128, .k8v8g64, .k8v8g64Dequant, .k6v6g64, .k6v6g64Dequant: 0
        }
    }

    public var quantizesKeys: Bool {
        switch self {
        case .fp16KV, .bf16KV, .fullVBF16, .fullVAffine4, .fullVTurbo4: false
        case .affine4, .affine8, .fullKVTurbo4, .turbo4v2, .k8v8g128, .k8v8g64, .k8v8g64Dequant, .k6v6g64, .k6v6g64Dequant: true
        }
    }

    public var quantizesValues: Bool {
        switch self {
        case .fp16KV, .bf16KV, .fullVBF16: false
        case .affine4, .affine8, .fullVAffine4, .fullVTurbo4, .fullKVTurbo4, .turbo4v2, .k8v8g128, .k8v8g64, .k8v8g64Dequant, .k6v6g64, .k6v6g64Dequant: true
        }
    }

    /// Stored bits-per-element for KEYS on the context-growing (full/global)
    /// attention layers. bf16 is 16 bits — same bytes as fp16 — so it yields NO
    /// capacity gain; this metric makes that explicit.
    public var storedBitsK: Int {
        switch self {
        case .fp16KV, .bf16KV, .fullVBF16, .fullVAffine4, .fullVTurbo4: 16
        case .affine8, .k8v8g128, .k8v8g64, .k8v8g64Dequant: 8
        case .k6v6g64, .k6v6g64Dequant: 6
        case .affine4, .fullKVTurbo4, .turbo4v2: 4
        }
    }

    /// Stored bits-per-element for VALUES on the context-growing layers.
    /// Note: bf16 is 16 bits (2 bytes) — same as fp16 — so `fullVBF16` yields no
    /// capacity gain, which the capacity metric must reflect honestly.
    public var storedBitsV: Int {
        switch self {
        case .fp16KV, .bf16KV, .fullVBF16: 16
        case .affine8, .k8v8g128, .k8v8g64, .k8v8g64Dequant: 8
        case .k6v6g64, .k6v6g64Dequant: 6
        case .affine4, .fullVAffine4, .fullVTurbo4, .fullKVTurbo4, .turbo4v2: 4
        }
    }

    /// Effective stored bits-per-element including affine scale+bias overhead
    /// (two fp16 values per quantization group). 16-bit (fp16/bf16) has no group
    /// overhead; sub-16-bit modes use their configured group size.
    private func effectiveBits(_ bits: Int) -> Double {
        guard bits < 16 else { return 16.0 }
        let group = Double(groupSize ?? 64)
        return Double(bits) + 32.0 / group  // + fp16 scale + fp16 bias per group
    }

    /// Effective KV bytes per token-per-(growing)-layer for the context-growing
    /// (full/global) attention layers, expressed per element of n_kv_heads*head_dim
    /// (so it's model-shape independent). Baseline fp16 K+V = 4.0 bytes/elem.
    public var effectiveKVBytesPerTokenPerElem: Double {
        (effectiveBits(storedBitsK) + effectiveBits(storedBitsV)) / 8.0
    }

    /// Headline capacity multiplier: how many more tokens can be admitted at fixed
    /// RAM vs fp16 (max-admitted-tokens scales ~linearly with this, weights aside).
    public var capacityRatioVsFP16: Double {
        let fp16Bytes = (16.0 + 16.0) / 8.0
        return fp16Bytes / max(effectiveKVBytesPerTokenPerElem, 1e-9)
    }

    public init?(parsing rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public static func parse(_ rawValue: String) throws -> KVQuantCandidateMode {
        guard let mode = KVQuantCandidateMode(rawValue: rawValue) else {
            throw KVQuantCandidateModeParseError(rawValue: rawValue)
        }
        return mode
    }
}

public struct KVQuantCandidateModeParseError: Error, LocalizedError, Sendable, Equatable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var errorDescription: String? {
        let allowed = KVQuantCandidateMode.allCases.map(\.rawValue).joined(separator: ", ")
        return "unknown KV quant mode '\(rawValue)'; expected one of: \(allowed)"
    }
}

public enum KVQuantGateConfigError: Error, LocalizedError, Sendable, Equatable {
    case emptyModelID
    case emptySuites
    case emptyContexts
    case invalidContext(Int)
    case invalidDecodeTokens(Int)
    case invalidIterations(Int)
    case missingThresholds(URL)

    public var errorDescription: String? {
        switch self {
        case .emptyModelID:
            return "modelID must not be empty"
        case .emptySuites:
            return "at least one KV quant suite is required"
        case .emptyContexts:
            return "at least one context length is required"
        case .invalidContext(let value):
            return "context length must be greater than zero: \(value)"
        case .invalidDecodeTokens(let value):
            return "decodeTokens must be greater than zero: \(value)"
        case .invalidIterations(let value):
            return "iterations must be greater than zero: \(value)"
        case .missingThresholds(let url):
            return "threshold file does not exist: \(url.path)"
        }
    }
}

public struct KVQuantGateConfig: Codable, Sendable, Equatable {
    public static let defaultPrompt = "Write a concise technical note about deterministic inference benchmarking."

    public let modelID: String
    public let modelDirectory: URL?
    public let reference: KVQuantCandidateMode
    public let candidate: KVQuantCandidateMode
    public let suites: [KVQuantSuite]
    public let contexts: [Int]
    public let decodeTokens: Int
    public let iterations: Int
    public let dataDirectory: URL?
    public let thresholds: URL?
    public let allowMissingData: Bool
    public let prompt: String

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case modelDirectory = "model_directory"
        case reference
        case candidate
        case suites
        case contexts
        case decodeTokens = "decode_tokens"
        case iterations
        case dataDirectory = "data_directory"
        case thresholds
        case allowMissingData = "allow_missing_data"
        case prompt
    }

    public init(
        modelID: String,
        modelDirectory: URL? = nil,
        reference: KVQuantCandidateMode,
        candidate: KVQuantCandidateMode,
        suites: [KVQuantSuite],
        contexts: [Int],
        decodeTokens: Int,
        iterations: Int,
        dataDirectory: URL?,
        thresholds: URL? = nil,
        allowMissingData: Bool,
        prompt: String = KVQuantGateConfig.defaultPrompt
    ) throws {
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelID.isEmpty else { throw KVQuantGateConfigError.emptyModelID }
        guard !suites.isEmpty else { throw KVQuantGateConfigError.emptySuites }
        let normalizedSuites = Self.normalizedSuites(suites)
        guard !contexts.isEmpty else { throw KVQuantGateConfigError.emptyContexts }
        for context in contexts where context <= 0 {
            throw KVQuantGateConfigError.invalidContext(context)
        }
        guard decodeTokens > 0 else { throw KVQuantGateConfigError.invalidDecodeTokens(decodeTokens) }
        guard iterations > 0 else { throw KVQuantGateConfigError.invalidIterations(iterations) }
        if let thresholds, !FileManager.default.fileExists(atPath: thresholds.path) {
            throw KVQuantGateConfigError.missingThresholds(thresholds)
        }

        self.modelID = normalizedModelID
        self.modelDirectory = modelDirectory?.standardizedFileURL
        self.reference = reference
        self.candidate = candidate
        self.suites = normalizedSuites
        self.contexts = contexts
        self.decodeTokens = decodeTokens
        self.iterations = iterations
        self.dataDirectory = dataDirectory?.standardizedFileURL
        self.thresholds = thresholds?.standardizedFileURL
        self.allowMissingData = allowMissingData
        self.prompt = prompt
    }

    private static func normalizedSuites(_ suites: [KVQuantSuite]) -> [KVQuantSuite] {
        var seen = Set<KVQuantSuite>()
        var normalized: [KVQuantSuite] = []

        func appendOnce(_ suite: KVQuantSuite) {
            guard !seen.contains(suite) else { return }
            seen.insert(suite)
            normalized.append(suite)
        }

        appendOnce(.capacity)
        for suite in suites {
            appendOnce(suite)
        }
        return normalized
    }
}

public enum KVQuantGateStatus: String, Codable, Sendable {
    case passed
    case failed
    case skipped
}

public struct KVQuantPassFail: Codable, Sendable, Equatable {
    public let status: KVQuantGateStatus
    public let passed: Bool
    public let skipped: Bool
    public let reason: String?
    public let failures: [String]

    enum CodingKeys: String, CodingKey {
        case status
        case passed = "pass"
        case skipped
        case reason
        case failures
    }

    public init(
        status: KVQuantGateStatus,
        passed: Bool,
        skipped: Bool,
        reason: String?,
        failures: [String]
    ) {
        self.status = status
        self.passed = passed
        self.skipped = skipped
        self.reason = reason
        self.failures = failures
    }

    public static func passed() -> KVQuantPassFail {
        KVQuantPassFail(status: .passed, passed: true, skipped: false, reason: nil, failures: [])
    }

    public static func skipped(_ reason: String) -> KVQuantPassFail {
        KVQuantPassFail(status: .skipped, passed: false, skipped: true, reason: reason, failures: [])
    }

    public static func failed(_ failures: [String], reason: String? = nil) -> KVQuantPassFail {
        KVQuantPassFail(status: .failed, passed: false, skipped: false, reason: reason, failures: failures)
    }

    public static func aggregate(_ reports: [KVQuantPassFail]) -> KVQuantPassFail {
        guard !reports.isEmpty else {
            return .skipped("no suite reports were produced")
        }

        let failures = reports.flatMap(\.failures)
        if !failures.isEmpty {
            return .failed(failures)
        }

        let skippedReasons = reports.compactMap { report in
            report.skipped ? report.reason : nil
        }
        if !skippedReasons.isEmpty {
            return .skipped(skippedReasons.joined(separator: "; "))
        }

        return .passed()
    }
}

public struct KVQuantMetricSummary: Codable, Sendable, Equatable {
    public let unit: String
    public let count: Int
    public let min: Double?
    public let max: Double?
    public let mean: Double?
    public let p50: Double?
    public let p90: Double?
    public let p95: Double?

    public init(unit: String, samples: [Double]) {
        let values = samples.filter { $0.isFinite }.sorted()
        self.unit = unit
        self.count = values.count
        self.min = values.first
        self.max = values.last
        if values.isEmpty {
            self.mean = nil
            self.p50 = nil
            self.p90 = nil
            self.p95 = nil
        } else {
            self.mean = values.reduce(0, +) / Double(values.count)
            self.p50 = Self.percentile(values, 0.50)
            self.p90 = Self.percentile(values, 0.90)
            self.p95 = Self.percentile(values, 0.95)
        }
    }

    private static func percentile(_ sortedValues: [Double], _ quantile: Double) -> Double? {
        guard !sortedValues.isEmpty else { return nil }
        guard sortedValues.count > 1 else { return sortedValues[0] }

        let clamped = Swift.min(1.0, Swift.max(0.0, quantile))
        let position = clamped * Double(sortedValues.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return sortedValues[lower] }

        let weight = position - Double(lower)
        return sortedValues[lower] + (sortedValues[upper] - sortedValues[lower]) * weight
    }
}

public struct KVQuantModelReport: Codable, Sendable, Equatable {
    public let modelID: String
    public let modelPath: String?
    public let suites: [KVQuantSuiteReport]
    public let passFail: KVQuantPassFail
    public let failures: [String]
    public let skipped: [String]

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case modelPath = "model_path"
        case suites
        case passFail = "pass_fail"
        case failures
        case skipped
    }

    public init(modelID: String, modelPath: String?, suites: [KVQuantSuiteReport]) {
        self.modelID = modelID
        self.modelPath = modelPath
        self.suites = suites
        self.passFail = KVQuantPassFail.aggregate(suites.map(\.passFail))
        self.failures = suites.flatMap(\.failures)
        self.skipped = suites.flatMap(\.skipped)
    }
}

public struct KVQuantGateReport: Codable, Sendable, Equatable {
    public let generatedAt: Date
    public let config: KVQuantGateConfig
    public let hardware: HardwareInfo?
    public let models: [KVQuantModelReport]
    public let passFail: KVQuantPassFail
    public let failures: [String]
    public let skipped: [String]
    public let thresholdReport: KVQuantThresholdReport?

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case config
        case hardware
        case models
        case passFail = "pass_fail"
        case failures
        case skipped
        case thresholdReport = "threshold_report"
    }

    public init(
        generatedAt: Date,
        config: KVQuantGateConfig,
        hardware: HardwareInfo?,
        models: [KVQuantModelReport],
        thresholdReport: KVQuantThresholdReport? = nil
    ) {
        self.generatedAt = generatedAt
        self.config = config
        self.hardware = hardware
        self.models = models
        self.thresholdReport = thresholdReport
        let aggregate = KVQuantPassFail.aggregate(models.map(\.passFail) + [thresholdReport?.passFail].compactMap { $0 })
        self.passFail = aggregate
        self.failures = models.flatMap(\.failures) + (thresholdReport?.failures ?? [])
        self.skipped = models.flatMap(\.skipped)
    }
}

public struct KVQuantThresholdReport: Codable, Sendable, Equatable {
    public let thresholdPath: String
    public let checks: [KVQuantThresholdCheck]
    public let passFail: KVQuantPassFail
    public let failures: [String]

    enum CodingKeys: String, CodingKey {
        case thresholdPath = "threshold_path"
        case checks
        case passFail = "pass_fail"
        case failures
    }

    public init(thresholdPath: String, checks: [KVQuantThresholdCheck]) {
        self.thresholdPath = thresholdPath
        self.checks = checks
        self.failures = checks.compactMap { $0.failureMessage }
        if checks.isEmpty {
            self.passFail = .skipped("no present metrics matched threshold rules")
        } else {
            self.passFail = failures.isEmpty ? .passed() : .failed(failures)
        }
    }
}

public struct KVQuantThresholdCheck: Codable, Sendable, Equatable {
    public let metric: String
    public let value: Double?
    public let min: Double?
    public let max: Double?
    public let status: KVQuantGateStatus
    public let failureMessage: String?

    enum CodingKeys: String, CodingKey {
        case metric
        case value
        case min
        case max
        case status
        case failureMessage = "failure_message"
    }
}
