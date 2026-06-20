import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ProviderCoreFoundation

public struct KVQuantPerformanceRunner {
    private static let minimumDecodeTPSRatio = 0.50

    public init() {}

    public func run(
        config: KVQuantGateConfig,
        suite: KVQuantSuite,
        hardware: HardwareInfo,
        modelDirectory explicitModelDirectory: URL?
    ) async -> KVQuantSuiteReport {
        let startedAt = Date()

        guard config.reference.isReference else {
            let reason = "reference mode '\(config.reference.rawValue)' is parsed but only fp16-kv baseline loading is wired"
            return .skipped(
                suite: suite,
                config: config,
                modelPath: explicitModelDirectory?.path,
                reason: reason,
                todos: ["Wire non-fp16 reference KV cache injection before running this mode."],
                startedAt: startedAt,
                endedAt: Date()
            )
        }

        guard let modelDirectory = explicitModelDirectory ?? config.modelDirectory ?? ModelScanner.resolveLocalPath(modelID: config.modelID) else {
            let reason = "local model snapshot for '\(config.modelID)' was not found in the HuggingFace cache and no modelDirectory was supplied"
            return .skipped(
                suite: suite,
                config: config,
                modelPath: nil,
                reason: reason,
                todos: ["Download the target MLX model or pass a local modelDirectory in KVQuantGateConfig."],
                startedAt: startedAt,
                endedAt: Date()
            )
        }

        let modelConfiguration = LocalMLXModelConfiguration(
            modelID: config.modelID,
            modelDirectory: modelDirectory
        )
        let readiness = LocalMLXModelReadiness.inspect(modelConfiguration)
        guard readiness.canAttemptLoad else {
            let issueList = readiness.issues.map { issue in
                if let detail = issue.detail {
                    return "\(issue.kind.rawValue) at \(issue.path.path): \(detail)"
                }
                return "\(issue.kind.rawValue) at \(issue.path.path)"
            }
            let reason = "local model snapshot is not ready to load: \(issueList.joined(separator: "; "))"
            return .skipped(
                suite: suite,
                config: config,
                modelPath: modelDirectory.path,
                reason: reason,
                startedAt: startedAt,
                endedAt: Date()
            )
        }

        do {
            let container = try await LocalMLXModelLoader.live().loadContainer(for: modelConfiguration)
            let baseParams = GenerateParameters(
                maxTokens: config.decodeTokens,
                temperature: 0.0,
                topP: 1.0,
                topK: 0
            )
            let referenceReport = try await runBaseline(
                label: "reference",
                mode: config.reference,
                container: container,
                config: config,
                cacheFactory: nil
            )

            let comparison: KVQuantPerformanceComparison
            let suitePassFail: KVQuantPassFail
            let skipped: [String]
            let todos: [String]

            if config.candidate.isReference {
                let candidateReport = relabel(referenceReport, label: "candidate", mode: config.candidate)
                comparison = KVQuantPerformanceComparison(
                    reference: referenceReport,
                    candidate: candidateReport,
                    notes: ["candidate is fp16-kv, so the reference baseline is reused"]
                )
                suitePassFail = .passed()
                skipped = []
                todos = []
            } else {
                let candidateExec = try KVQuantExecution.config(for: config.candidate, base: baseParams)
                let rawCandidateReport = try await runBaseline(
                    label: "candidate",
                    mode: config.candidate,
                    container: container,
                    config: config,
                    cacheFactory: candidateExec.cacheFactory
                )
                let gate = Self.evaluatePerfGate(reference: referenceReport, candidate: rawCandidateReport)
                let candidateReport = gate.candidate
                comparison = KVQuantPerformanceComparison(
                    reference: referenceReport,
                    candidate: candidateReport,
                    notes: gate.notes
                )
                // The decode-TPS regression gate only governs the performance
                // suite. The memory suite shares this runner to collect the same
                // measurements, but its pass/fail is owned by memory/threshold
                // evaluation — it must not fail solely on candidate throughput.
                suitePassFail = (suite == .performance) ? gate.passFail : .passed()
                skipped = []
                todos = [
                    "This perf suite is a fail-safe sequential regression gate. Use kv-engine-demo --concurrency-sweep for the live continuous-batching diagnostic."
                ]
            }

            return KVQuantSuiteReport(
                suite: suite,
                modelID: config.modelID,
                modelPath: modelDirectory.path,
                reference: config.reference,
                candidate: config.candidate,
                contexts: config.contexts,
                iterationCount: config.iterations,
                startedAt: startedAt,
                endedAt: Date(),
                performance: comparison,
                quality: nil,
                passFail: suitePassFail,
                failures: suitePassFail.failures,
                skipped: skipped,
                todos: todos
            )
        } catch {
            return .failed(
                suite: suite,
                config: config,
                modelPath: modelDirectory.path,
                failures: ["failed to load or run model '\(config.modelID)': \(error.localizedDescription)"],
                startedAt: startedAt,
                endedAt: Date()
            )
        }
    }

    private func runBaseline(
        label: String,
        mode: KVQuantCandidateMode,
        container: ModelContainer,
        config: KVQuantGateConfig,
        cacheFactory: (@Sendable (any LanguageModel) -> [KVCache])?
    ) async throws -> KVQuantPerformanceReport {
        // Reset the high-water mark so this baseline's peak is measured independently
        // of any earlier reference/candidate runs in the same process.
        MLX.Memory.peakMemory = 0

        var iterations: [KVQuantIterationReport] = []
        var outputs: [KVQuantOutputSample] = []
        var snapshots: [KVQuantMemorySnapshot] = [Self.captureMemory(label: "\(label).start")]

        for context in config.contexts {
            let prompt = Self.prompt(base: config.prompt, targetContextTokens: context)
            for iteration in 1...config.iterations {
                let result = try await runIteration(
                    label: label,
                    mode: mode,
                    context: context,
                    iteration: iteration,
                    prompt: prompt,
                    decodeTokens: config.decodeTokens,
                    container: container,
                    cacheFactory: cacheFactory
                )
                iterations.append(result.report)
                outputs.append(result.output)
                snapshots.append(result.report.memoryBefore)
                snapshots.append(result.report.memoryAfter)
            }
        }

        snapshots.append(Self.captureMemory(label: "\(label).end"))

        let metrics = Self.metrics(for: iterations)
        return KVQuantPerformanceReport(
            label: label,
            mode: mode,
            iterations: iterations,
            metrics: metrics,
            memory: KVQuantMemorySummary(snapshots: snapshots),
            outputs: outputs,
            passFail: iterations.isEmpty ? .skipped("no iterations were run") : .passed()
        )
    }

    private func runIteration(
        label: String,
        mode: KVQuantCandidateMode,
        context: Int,
        iteration: Int,
        prompt: String,
        decodeTokens: Int,
        container: ModelContainer,
        cacheFactory: (@Sendable (any LanguageModel) -> [KVCache])?
    ) async throws -> (report: KVQuantIterationReport, output: KVQuantOutputSample) {
        let rawMessages: [MLXLMCommon.Message] = [
            ["role": "user", "content": prompt] as MLXLMCommon.Message,
        ]

        let before = Self.captureMemory(label: "\(label).context\(context).iteration\(iteration).before")
        let iterationStart = ContinuousClock.now

        let generationStream: AsyncStream<Generation> = try await container.perform { context in
            let input = try await context.processor.prepare(input: UserInput(messages: rawMessages))
            let params = GenerateParameters(
                maxTokens: decodeTokens,
                temperature: 0.0,
                topP: 1.0,
                topK: 0
            )
            let cache = cacheFactory?(context.model)
            return try MLXLMCommon.generate(input: input, cache: cache, parameters: params, context: context)
        }

        var output = ""
        var promptTokens = 0
        var completionTokens = 0
        var prefillLatencyMs: Double = 0
        var firstTokenTime: ContinuousClock.Instant?

        for await generation in generationStream {
            switch generation {
            case .chunk(let text):
                if firstTokenTime == nil {
                    firstTokenTime = .now
                    prefillLatencyMs = Self.milliseconds(from: iterationStart, to: firstTokenTime!)
                }
                output += text

            case .info(let info):
                promptTokens = info.promptTokenCount
                completionTokens = info.generationTokenCount
                if prefillLatencyMs == 0 {
                    prefillLatencyMs = info.promptTime * 1000
                }

            case .toolCall:
                break
            }
        }

        let totalTimeMs = Self.milliseconds(from: iterationStart, to: .now)
        let decodeTimeMs = max(0, totalTimeMs - prefillLatencyMs)
        let decodeTokensPerSecond = completionTokens > 0 && decodeTimeMs > 0
            ? Double(completionTokens) / (decodeTimeMs / 1000)
            : 0
        let after = Self.captureMemory(label: "\(label).context\(context).iteration\(iteration).after")

        let report = KVQuantIterationReport(
            label: label,
            mode: mode,
            context: context,
            iteration: iteration,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            prefillLatencyMs: prefillLatencyMs,
            decodeTokensPerSecond: decodeTokensPerSecond,
            totalTimeMs: totalTimeMs,
            memoryBefore: before,
            memoryAfter: after
        )
        let sample = KVQuantOutputSample(
            label: label,
            context: context,
            iteration: iteration,
            output: output
        )
        return (report, sample)
    }

    private func relabel(
        _ report: KVQuantPerformanceReport,
        label: String,
        mode: KVQuantCandidateMode
    ) -> KVQuantPerformanceReport {
        KVQuantPerformanceReport(
            label: label,
            mode: mode,
            iterations: report.iterations,
            metrics: report.metrics,
            memory: report.memory,
            outputs: report.outputs,
            passFail: report.passFail
        )
    }

    private static func evaluatePerfGate(
        reference: KVQuantPerformanceReport,
        candidate: KVQuantPerformanceReport
    ) -> (candidate: KVQuantPerformanceReport, passFail: KVQuantPassFail, notes: [String]) {
        let ratios = zip(reference.iterations, candidate.iterations).compactMap { ref, cand -> Double? in
            guard ref.decodeTokensPerSecond > 0, cand.decodeTokensPerSecond > 0 else { return nil }
            return cand.decodeTokensPerSecond / ref.decodeTokensPerSecond
        }
        var metrics = candidate.metrics
        metrics["perf.decode_tps_ratio"] = KVQuantMetricSummary(unit: "ratio", samples: ratios)
        let enriched = KVQuantPerformanceReport(
            label: candidate.label,
            mode: candidate.mode,
            iterations: candidate.iterations,
            metrics: metrics,
            memory: candidate.memory,
            outputs: candidate.outputs,
            passFail: candidate.passFail
        )

        guard !ratios.isEmpty else {
            return (
                enriched,
                .failed(["perf.decode_tps_ratio missing: no paired reference/candidate decode TPS samples"]),
                ["perf.decode_tps_ratio missing"]
            )
        }
        let ratioSummary = KVQuantMetricSummary(unit: "ratio", samples: ratios)
        let p50 = ratioSummary.p50 ?? 0
        let note = "perf.decode_tps_ratio p50=\(String(format: "%.3f", p50)) minimum=\(String(format: "%.3f", minimumDecodeTPSRatio))"
        if p50 < minimumDecodeTPSRatio {
            return (
                enriched,
                .failed(["\(note): candidate decode TPS regressed beyond default threshold"]),
                [note]
            )
        }
        return (enriched, .passed(), [note])
    }

    private static func metrics(for iterations: [KVQuantIterationReport]) -> [String: KVQuantMetricSummary] {
        [
            "prefill_latency_ms": KVQuantMetricSummary(
                unit: "milliseconds",
                samples: iterations.map(\.prefillLatencyMs)
            ),
            "decode_tokens_per_second": KVQuantMetricSummary(
                unit: "tokens_per_second",
                samples: iterations.map(\.decodeTokensPerSecond)
            ),
            "total_time_ms": KVQuantMetricSummary(
                unit: "milliseconds",
                samples: iterations.map(\.totalTimeMs)
            ),
            "prompt_tokens": KVQuantMetricSummary(
                unit: "tokens",
                samples: iterations.map { Double($0.promptTokens) }
            ),
            "completion_tokens": KVQuantMetricSummary(
                unit: "tokens",
                samples: iterations.map { Double($0.completionTokens) }
            ),
        ]
    }

    private static func captureMemory(label: String) -> KVQuantMemorySnapshot {
        KVQuantMemorySnapshot(
            label: label,
            capturedAt: Date(),
            mlxGPUActiveBytes: UInt64(max(0, MLX.Memory.activeMemory)),
            mlxGPUPeakBytes: UInt64(max(0, MLX.Memory.peakMemory)),
            mlxGPUCacheBytes: UInt64(max(0, MLX.Memory.cacheMemory)),
            systemAvailableBytes: SystemMemory.availableBytes()
        )
    }

    private static func milliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Double {
        let elapsed = end - start
        let components = elapsed.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    private static func prompt(base: String, targetContextTokens: Int) -> String {
        let targetCharacters = max(base.count, targetContextTokens * 4)
        guard targetCharacters > base.count else { return base }

        let filler = "\nBenchmark context filler: deterministic KV quant gate prefill text."
        var prompt = base
        while prompt.count < targetCharacters {
            prompt += filler
        }
        return prompt
    }
}
