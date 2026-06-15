import Foundation

public struct KVQuantMemorySnapshot: Codable, Sendable, Equatable {
    public let label: String
    public let capturedAt: Date
    public let mlxGPUActiveBytes: UInt64
    public let mlxGPUPeakBytes: UInt64
    public let mlxGPUCacheBytes: UInt64
    public let systemAvailableBytes: UInt64?

    enum CodingKeys: String, CodingKey {
        case label
        case capturedAt = "captured_at"
        case mlxGPUActiveBytes = "mlx_gpu_active_bytes"
        case mlxGPUPeakBytes = "mlx_gpu_peak_bytes"
        case mlxGPUCacheBytes = "mlx_gpu_cache_bytes"
        case systemAvailableBytes = "system_available_bytes"
    }

    public init(
        label: String,
        capturedAt: Date,
        mlxGPUActiveBytes: UInt64,
        mlxGPUPeakBytes: UInt64,
        mlxGPUCacheBytes: UInt64,
        systemAvailableBytes: UInt64?
    ) {
        self.label = label
        self.capturedAt = capturedAt
        self.mlxGPUActiveBytes = mlxGPUActiveBytes
        self.mlxGPUPeakBytes = mlxGPUPeakBytes
        self.mlxGPUCacheBytes = mlxGPUCacheBytes
        self.systemAvailableBytes = systemAvailableBytes
    }
}

public struct KVQuantMemorySummary: Codable, Sendable, Equatable {
    public let snapshots: [KVQuantMemorySnapshot]
    public let mlxGPUActiveBytes: KVQuantMetricSummary
    public let mlxGPUPeakBytes: KVQuantMetricSummary
    public let mlxGPUCacheBytes: KVQuantMetricSummary
    public let systemAvailableBytes: KVQuantMetricSummary?

    enum CodingKeys: String, CodingKey {
        case snapshots
        case mlxGPUActiveBytes = "mlx_gpu_active_bytes"
        case mlxGPUPeakBytes = "mlx_gpu_peak_bytes"
        case mlxGPUCacheBytes = "mlx_gpu_cache_bytes"
        case systemAvailableBytes = "system_available_bytes"
    }

    public init(snapshots: [KVQuantMemorySnapshot]) {
        self.snapshots = snapshots
        self.mlxGPUActiveBytes = KVQuantMetricSummary(
            unit: "bytes",
            samples: snapshots.map { Double($0.mlxGPUActiveBytes) }
        )
        self.mlxGPUPeakBytes = KVQuantMetricSummary(
            unit: "bytes",
            samples: snapshots.map { Double($0.mlxGPUPeakBytes) }
        )
        self.mlxGPUCacheBytes = KVQuantMetricSummary(
            unit: "bytes",
            samples: snapshots.map { Double($0.mlxGPUCacheBytes) }
        )

        let available = snapshots.compactMap(\.systemAvailableBytes).map { Double($0) }
        self.systemAvailableBytes = available.isEmpty ? nil : KVQuantMetricSummary(unit: "bytes", samples: available)
    }
}

public struct KVQuantOutputSample: Codable, Sendable, Equatable {
    public let label: String
    public let context: Int
    public let iteration: Int
    public let characterCount: Int
    public let sha256: String
    public let preview: String

    enum CodingKeys: String, CodingKey {
        case label
        case context
        case iteration
        case characterCount = "character_count"
        case sha256
        case preview
    }

    public init(label: String, context: Int, iteration: Int, output: String, previewLimit: Int = 512) {
        self.label = label
        self.context = context
        self.iteration = iteration
        self.characterCount = output.count
        self.sha256 = sha256Hex(Data(output.utf8))
        self.preview = String(output.prefix(previewLimit))
    }
}

public struct KVQuantIterationReport: Codable, Sendable, Equatable {
    public let label: String
    public let mode: KVQuantCandidateMode
    public let context: Int
    public let iteration: Int
    public let promptTokens: Int
    public let completionTokens: Int
    public let prefillLatencyMs: Double
    public let decodeTokensPerSecond: Double
    public let totalTimeMs: Double
    public let memoryBefore: KVQuantMemorySnapshot
    public let memoryAfter: KVQuantMemorySnapshot

    enum CodingKeys: String, CodingKey {
        case label
        case mode
        case context
        case iteration
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case prefillLatencyMs = "prefill_latency_ms"
        case decodeTokensPerSecond = "decode_tokens_per_second"
        case totalTimeMs = "total_time_ms"
        case memoryBefore = "memory_before"
        case memoryAfter = "memory_after"
    }

    public init(
        label: String,
        mode: KVQuantCandidateMode,
        context: Int,
        iteration: Int,
        promptTokens: Int,
        completionTokens: Int,
        prefillLatencyMs: Double,
        decodeTokensPerSecond: Double,
        totalTimeMs: Double,
        memoryBefore: KVQuantMemorySnapshot,
        memoryAfter: KVQuantMemorySnapshot
    ) {
        self.label = label
        self.mode = mode
        self.context = context
        self.iteration = iteration
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.prefillLatencyMs = prefillLatencyMs
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.totalTimeMs = totalTimeMs
        self.memoryBefore = memoryBefore
        self.memoryAfter = memoryAfter
    }
}

public struct KVQuantPerformanceReport: Codable, Sendable, Equatable {
    public let label: String
    public let mode: KVQuantCandidateMode
    public let iterations: [KVQuantIterationReport]
    public let metrics: [String: KVQuantMetricSummary]
    public let memory: KVQuantMemorySummary
    public let outputs: [KVQuantOutputSample]
    public let passFail: KVQuantPassFail

    enum CodingKeys: String, CodingKey {
        case label
        case mode
        case iterations
        case metrics
        case memory
        case outputs
        case passFail = "pass_fail"
    }

    public init(
        label: String,
        mode: KVQuantCandidateMode,
        iterations: [KVQuantIterationReport],
        metrics: [String: KVQuantMetricSummary],
        memory: KVQuantMemorySummary,
        outputs: [KVQuantOutputSample],
        passFail: KVQuantPassFail
    ) {
        self.label = label
        self.mode = mode
        self.iterations = iterations
        self.metrics = metrics
        self.memory = memory
        self.outputs = outputs
        self.passFail = passFail
    }
}

public struct KVQuantPerformanceComparison: Codable, Sendable, Equatable {
    public let reference: KVQuantPerformanceReport?
    public let candidate: KVQuantPerformanceReport?
    public let notes: [String]

    public init(
        reference: KVQuantPerformanceReport?,
        candidate: KVQuantPerformanceReport?,
        notes: [String]
    ) {
        self.reference = reference
        self.candidate = candidate
        self.notes = notes
    }
}

public struct KVQuantQualityReport: Codable, Sendable, Equatable {
    public let suite: KVQuantSuite
    public let metricName: String
    public let dataDirectory: URL?
    public let metrics: [String: KVQuantMetricSummary]
    public let passFail: KVQuantPassFail
    public let todos: [String]

    enum CodingKeys: String, CodingKey {
        case suite
        case metricName = "metric_name"
        case dataDirectory = "data_directory"
        case metrics
        case passFail = "pass_fail"
        case todos
    }

    public init(
        suite: KVQuantSuite,
        metricName: String,
        dataDirectory: URL?,
        metrics: [String: KVQuantMetricSummary],
        passFail: KVQuantPassFail,
        todos: [String]
    ) {
        self.suite = suite
        self.metricName = metricName
        self.dataDirectory = dataDirectory
        self.metrics = metrics
        self.passFail = passFail
        self.todos = todos
    }
}

public struct KVQuantSuiteReport: Codable, Sendable, Equatable {
    public let suite: KVQuantSuite
    public let modelID: String
    public let modelPath: String?
    public let reference: KVQuantCandidateMode
    public let candidate: KVQuantCandidateMode
    public let contexts: [Int]
    public let iterationCount: Int
    public let startedAt: Date
    public let endedAt: Date
    public let performance: KVQuantPerformanceComparison?
    public let quality: KVQuantQualityReport?
    public let passFail: KVQuantPassFail
    public let failures: [String]
    public let skipped: [String]
    public let todos: [String]

    enum CodingKeys: String, CodingKey {
        case suite
        case modelID = "model_id"
        case modelPath = "model_path"
        case reference
        case candidate
        case contexts
        case iterationCount = "iteration_count"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case performance
        case quality
        case passFail = "pass_fail"
        case failures
        case skipped
        case todos
    }

    public init(
        suite: KVQuantSuite,
        modelID: String,
        modelPath: String?,
        reference: KVQuantCandidateMode,
        candidate: KVQuantCandidateMode,
        contexts: [Int],
        iterationCount: Int,
        startedAt: Date,
        endedAt: Date,
        performance: KVQuantPerformanceComparison?,
        quality: KVQuantQualityReport?,
        passFail: KVQuantPassFail,
        failures: [String],
        skipped: [String],
        todos: [String]
    ) {
        self.suite = suite
        self.modelID = modelID
        self.modelPath = modelPath
        self.reference = reference
        self.candidate = candidate
        self.contexts = contexts
        self.iterationCount = iterationCount
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.performance = performance
        self.quality = quality
        self.passFail = passFail
        self.failures = failures
        self.skipped = skipped
        self.todos = todos
    }

    public static func skipped(
        suite: KVQuantSuite,
        config: KVQuantGateConfig,
        modelPath: String?,
        reason: String,
        todos: [String] = [],
        startedAt: Date = Date(),
        endedAt: Date = Date()
    ) -> KVQuantSuiteReport {
        KVQuantSuiteReport(
            suite: suite,
            modelID: config.modelID,
            modelPath: modelPath,
            reference: config.reference,
            candidate: config.candidate,
            contexts: config.contexts,
            iterationCount: config.iterations,
            startedAt: startedAt,
            endedAt: endedAt,
            performance: nil,
            quality: nil,
            passFail: .skipped(reason),
            failures: [],
            skipped: [reason],
            todos: todos
        )
    }

    public static func failed(
        suite: KVQuantSuite,
        config: KVQuantGateConfig,
        modelPath: String?,
        failures: [String],
        todos: [String] = [],
        startedAt: Date = Date(),
        endedAt: Date = Date()
    ) -> KVQuantSuiteReport {
        KVQuantSuiteReport(
            suite: suite,
            modelID: config.modelID,
            modelPath: modelPath,
            reference: config.reference,
            candidate: config.candidate,
            contexts: config.contexts,
            iterationCount: config.iterations,
            startedAt: startedAt,
            endedAt: endedAt,
            performance: nil,
            quality: nil,
            passFail: .failed(failures),
            failures: failures,
            skipped: [],
            todos: todos
        )
    }
}
