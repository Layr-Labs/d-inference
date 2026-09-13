import MLXLMCommon
import ProviderCore

enum SchedulerPrefillDecisionScenarios {
    static let qwenModeledPromptTokensPerSecond = 1531.0
    static let partialPrefillCaps = [0, 1]

    static let qwenEvaluationWorkloads: [SchedulerPrefillDecisionReport.Workload] = [
        .init(
            name: "burst-4x4k",
            rows: Array(
                repeating: .init(promptTokens: 4096, arrivalMs: 0),
                count: 4)),
        .init(
            name: "burst-4x8k",
            rows: Array(
                repeating: .init(promptTokens: 8192, arrivalMs: 0),
                count: 4)),
        .init(
            name: "stagger-t0-tplus2-4x8k",
            rows: [
                .init(promptTokens: 8192, arrivalMs: 0),
                .init(promptTokens: 8192, arrivalMs: 0),
                .init(promptTokens: 8192, arrivalMs: 2000),
                .init(promptTokens: 8192, arrivalMs: 2000),
            ]),
        // Long-first is deliberate. FCFS must expose its head-of-line cost.
        .init(
            name: "mixed-long-first",
            rows: [
                .init(promptTokens: 8192, arrivalMs: 0),
                .init(promptTokens: 1024, arrivalMs: 0),
                .init(promptTokens: 4096, arrivalMs: 0),
                .init(promptTokens: 2048, arrivalMs: 0),
            ]),
        // A resident decoder disarms the solo stripe. Cap 1 can still present
        // a two-row packed cohort at the final-chunk/successor handoff.
        .init(
            name: "active-decode-plus-4x4k",
            activeDecode: true,
            rows: Array(
                repeating: .init(promptTokens: 4096, arrivalMs: 0),
                count: 4)),
    ]

    // Compatibility for the existing benchmark entry point. These are policy
    // evaluation workloads, not release certification.
    static let qwenReleaseWorkloads = qwenEvaluationWorkloads

    static func configuration(
        modeledPromptTokensPerSecond: Double?,
        timingBasis: String
    ) -> SchedulerPrefillDecisionReport.Configuration {
        SchedulerPrefillDecisionReport.Configuration(
            maxConcurrentRequests: Int(BackendSettings.defaultEngineV2MaxConcurrent),
            maxBatchedTokensPerStep: 2048,
            prefillChunkTokens: 512,
            soloPrefillStripeTokens: EngineV2Factory.defaultSoloPrefillStripeTokens,
            modeledPromptTokensPerSecond: modeledPromptTokensPerSecond,
            timingBasis: timingBasis)
    }
}

enum SchedulerPrefillDecisionActiveDecodeBudget {
    /// One token is consumed while establishing that decode is resident. The
    /// measurement can then consume at most one decode token per engine step.
    /// Bound the sentinel from the actual prompt-chunk work (and the simulator's
    /// exact step count when available), with enough slack for finalization and
    /// capacity requeues. This replaces the admission-hostile million-token
    /// reservation without making production admission less strict.
    static func maxTokens(
        workload: SchedulerPrefillDecisionReport.Workload,
        schedulerSteps: Int?,
        configuration: SchedulerPrefillDecisionReport.Configuration
    ) throws -> Int {
        guard workload.activeDecode, configuration.prefillChunkTokens > 0 else {
            throw SchedulerPrefillDecisionError.activeDecodeBudgetUnavailable(
                workload: workload.name,
                reason: "active workload and positive prefill chunk size required")
        }
        guard workload.rows.allSatisfy({ $0.arrivalMs == 0 }) else {
            throw SchedulerPrefillDecisionError.activeDecodeBudgetUnavailable(
                workload: workload.name,
                reason: "active-decode join currently requires zero-arrival rows")
        }

        var promptChunkSteps = 0
        for row in workload.rows {
            guard row.promptTokens > 0 else {
                throw SchedulerPrefillDecisionError.activeDecodeBudgetUnavailable(
                    workload: workload.name,
                    reason: "prompt rows must be positive")
            }
            let (rounded, roundingOverflow) = row.promptTokens.addingReportingOverflow(
                configuration.prefillChunkTokens - 1)
            guard !roundingOverflow else {
                throw SchedulerPrefillDecisionError.activeDecodeBudgetUnavailable(
                    workload: workload.name,
                    reason: "prompt chunk count overflow")
            }
            let chunks = rounded / configuration.prefillChunkTokens
            let (next, totalOverflow) = promptChunkSteps.addingReportingOverflow(chunks)
            guard !totalOverflow else {
                throw SchedulerPrefillDecisionError.activeDecodeBudgetUnavailable(
                    workload: workload.name,
                    reason: "aggregate prompt chunk count overflow")
            }
            promptChunkSteps = next
        }

        let measuredSteps = max(promptChunkSteps, max(0, schedulerSteps ?? 0))
        let safetyTokens = max(8, measuredSteps / 2)
        let (withBootstrap, bootstrapOverflow) = measuredSteps.addingReportingOverflow(2)
        let (measurementBudget, measurementOverflow) = withBootstrap.addingReportingOverflow(
            safetyTokens)
        // Before the first token reaches the harness, chained decode can get
        // ahead only until the production stream's bounded buffer pauses it,
        // plus the engine's at-most-two in-flight steps. The runner submits
        // every measurement row synchronously from that first-token callback,
        // which breaks the chain before it signals readiness.
        let (startupBudget, startupOverflow) =
            CBv2EngineLoopConfig().eventBufferCapacity.addingReportingOverflow(4)
        let (budget, budgetOverflow) = startupBudget.addingReportingOverflow(
            measurementBudget)
        guard !bootstrapOverflow, !measurementOverflow, !startupOverflow,
            !budgetOverflow, budget > 0
        else {
            throw SchedulerPrefillDecisionError.activeDecodeBudgetUnavailable(
                workload: workload.name,
                reason: "decode token budget overflow")
        }
        return budget
    }
}

struct SchedulerPrefillDecisionCell: Hashable, Sendable {
    let workloadName: String
    let maxConcurrentPartialPrefills: Int

    init(
        workload: SchedulerPrefillDecisionReport.Workload,
        maxConcurrentPartialPrefills: Int
    ) {
        workloadName = workload.name
        self.maxConcurrentPartialPrefills = maxConcurrentPartialPrefills
    }

    init(result: SchedulerPrefillDecisionReport.Result) {
        self.init(
            workload: result.workload,
            maxConcurrentPartialPrefills: result.maxConcurrentPartialPrefills)
    }
}

struct SchedulerPrefillDecisionIndexedRow: Sendable {
    let index: Int
    let input: SchedulerPrefillDecisionReport.WorkloadRow
}

extension SchedulerPrefillDecisionReport.Workload {
    var orderedRows: [SchedulerPrefillDecisionIndexedRow] {
        rows.enumerated()
            .map { SchedulerPrefillDecisionIndexedRow(index: $0.offset, input: $0.element) }
            .sorted {
                if $0.input.arrivalMs != $1.input.arrivalMs {
                    return $0.input.arrivalMs < $1.input.arrivalMs
                }
                return $0.index < $1.index
            }
    }

    var totalPromptTokens: Int {
        rows.reduce(0) { $0 + $1.promptTokens }
    }
}

enum SchedulerPrefillDecisionError: Error, CustomStringConvertible {
    case invalidPromptTokensPerSecond(Double)
    case invalidModelConfig
    case invalidModelIdentifier
    case unexpectedModelType(String)
    case modelHashUnavailable
    case modelHashMismatch(expected: String, actual: String)
    case executableHashUnavailable
    case invalidLivePosture(String)
    case activeDecodeBudgetUnavailable(workload: String, reason: String)
    case activeDecodeCapacityInsufficient(
        workload: String,
        maxTokens: Int,
        kvBytesCapacity: Int,
        kvBytesReserved: Int,
        reason: String)
    case activeDecodeEndedEarly(
        workload: String,
        maxTokens: Int,
        generatedTokens: Int,
        reason: String)
    case activeDecodeBootstrapFailed(String)
    case schedulerStalled(String)
    case missingFirstToken(workload: String, row: Int)
    case liveRowProducedNoToken(workload: String, row: Int)
    case liveRowFailed(workload: String, row: Int, reason: String)
    case activeDecodeFailed(workload: String, reason: String)

    var description: String {
        switch self {
        case .invalidPromptTokensPerSecond(let value):
            return "prompt token rate must be finite and positive, got \(value)"
        case .invalidModelConfig:
            return "selected checkpoint has no readable JSON config"
        case .invalidModelIdentifier:
            return "model identifier must be a registry label, not a local path"
        case .unexpectedModelType(let value):
            return "selected checkpoint model_type must be qwen3_5_moe; got \(value)"
        case .modelHashUnavailable:
            return "selected checkpoint config or aggregate hash is unavailable"
        case .modelHashMismatch(let expected, let actual):
            return "selected checkpoint aggregate hash mismatch: expected \(expected), "
                + "got \(actual)"
        case .executableHashUnavailable:
            return "evaluation executable SHA-256 is unavailable"
        case .invalidLivePosture(let detail):
            return "live policy evaluation requires controlled power/thermal posture: "
                + detail
        case .activeDecodeBudgetUnavailable(let workload, let reason):
            return "\(workload): cannot derive bounded active-decode evidence budget: "
                + reason
        case .activeDecodeCapacityInsufficient(
            let workload,
            let maxTokens,
            let kvBytesCapacity,
            let kvBytesReserved,
            let reason
        ):
            return "\(workload): host cannot admit the minimum active-decode evidence "
                + "budget of \(maxTokens) tokens "
                + "(kv_capacity=\(kvBytesCapacity), kv_reserved=\(kvBytesReserved)): "
                + reason
        case .activeDecodeEndedEarly(
            let workload,
            let maxTokens,
            let generatedTokens,
            let reason
        ):
            return "\(workload): active-decode sentinel ended before measurement "
                + "completion after \(generatedTokens)/\(maxTokens) tokens: \(reason)"
        case .activeDecodeBootstrapFailed(let workload):
            return "\(workload): failed to establish a decode-ready row"
        case .schedulerStalled(let workload):
            return "\(workload): scheduler made no prompt progress"
        case .missingFirstToken(let workload, let row):
            return "\(workload): row \(row) never reached first token"
        case .liveRowProducedNoToken(let workload, let row):
            return "\(workload): live row \(row) produced no token"
        case .liveRowFailed(let workload, let row, let reason):
            return "\(workload): live row \(row) failed: \(reason)"
        case .activeDecodeFailed(let workload, let reason):
            return "\(workload): could not establish active decode: \(reason)"
        }
    }
}
