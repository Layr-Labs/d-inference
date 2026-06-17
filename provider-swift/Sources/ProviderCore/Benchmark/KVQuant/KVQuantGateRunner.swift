import Foundation
import ProviderCoreFoundation

public struct KVQuantGateRunner {
    private let config: KVQuantGateConfig
    private let performanceRunner: KVQuantPerformanceRunner
    private let qualityRunner: KVQuantQualityRunner
    private let outputSmokeRunner: KVQuantOutputSmokeRunner

    public init(
        config: KVQuantGateConfig,
        performanceRunner: KVQuantPerformanceRunner = KVQuantPerformanceRunner(),
        qualityRunner: KVQuantQualityRunner = KVQuantQualityRunner(),
        outputSmokeRunner: KVQuantOutputSmokeRunner = KVQuantOutputSmokeRunner()
    ) {
        self.config = config
        self.performanceRunner = performanceRunner
        self.qualityRunner = qualityRunner
        self.outputSmokeRunner = outputSmokeRunner
    }

    public static func run(_ config: KVQuantGateConfig) async throws -> KVQuantGateReport {
        await KVQuantGateRunner(config: config).run()
    }

    public func run() async -> KVQuantGateReport {
        let generatedAt = Date()
        let modelDirectory = config.modelDirectory ?? ModelScanner.resolveLocalPath(modelID: config.modelID)

        do {
            let hardware = try HardwareDetector.detect()
            let suites = await runSuites(hardware: hardware, modelDirectory: modelDirectory)
            let modelReport = KVQuantModelReport(
                modelID: config.modelID,
                modelPath: modelDirectory?.path,
                suites: suites
            )
            let baseReport = KVQuantGateReport(
                generatedAt: generatedAt,
                config: config,
                hardware: hardware,
                models: [modelReport]
            )
            let thresholdReport = config.thresholds.flatMap {
                KVQuantThresholdEvaluator.evaluate(report: baseReport, thresholdsURL: $0, hardware: hardware)
            }
            return KVQuantGateReport(
                generatedAt: generatedAt,
                config: config,
                hardware: hardware,
                models: [modelReport],
                thresholdReport: thresholdReport
            )
        } catch {
            let reason = "hardware detection failed: \(error.localizedDescription)"
            let suites = config.suites.map { suite in
                KVQuantSuiteReport.skipped(
                    suite: suite,
                    config: config,
                    modelPath: modelDirectory?.path,
                    reason: reason
                )
            }
            let modelReport = KVQuantModelReport(
                modelID: config.modelID,
                modelPath: modelDirectory?.path,
                suites: suites
            )
            return KVQuantGateReport(
                generatedAt: generatedAt,
                config: config,
                hardware: nil,
                models: [modelReport]
            )
        }
    }

    /// Model-free analytic capacity report: the headline KV-bytes-per-token and
    /// the resulting max-admitted-tokens multiplier vs fp16. This is the metric the
    /// whole effort optimizes (capacity = (RAM - weights)/kv_bytes_per_token).
    static func capacityReport(config: KVQuantGateConfig, modelDirectory: URL?) -> KVQuantSuiteReport {
        let now = Date()
        let cand = config.candidate
        let ref = config.reference
        let candBytes = cand.effectiveKVBytesPerTokenPerElem
        let refBytes = ref.effectiveKVBytesPerTokenPerElem
        var metrics: [String: KVQuantMetricSummary] = [
            "capacity.kv_bytes_per_token_per_elem": .init(unit: "bytes", samples: [cand.effectiveKVBytesPerTokenPerElem]),
            "capacity.reference_kv_bytes_per_token_per_elem": .init(unit: "bytes", samples: [ref.effectiveKVBytesPerTokenPerElem]),
            "capacity.kv_bytes_per_token_ratio_vs_reference": .init(unit: "ratio", samples: [candBytes / max(refBytes, 1e-9)]),
            "capacity.max_admitted_tokens_ratio_vs_reference": .init(unit: "x", samples: [refBytes / max(candBytes, 1e-9)]),
            "capacity.kv_token_ratio_vs_fp16": .init(unit: "x", samples: [cand.capacityRatioVsFP16]),
            "capacity.stored_bits_k": .init(unit: "bits", samples: [Double(cand.storedBitsK)]),
            "capacity.stored_bits_v": .init(unit: "bits", samples: [Double(cand.storedBitsV)]),
        ]
        for (name, summary) in liveCapacityMetrics(config: config, modelDirectory: modelDirectory) {
            metrics[name] = summary
        }
        let quality = KVQuantQualityReport(
            suite: .capacity,
            metricName: "capacity",
            dataDirectory: config.dataDirectory,
            metrics: metrics,
            passFail: .passed(),
            todos: []
        )
        return KVQuantSuiteReport(
            suite: .capacity,
            modelID: config.modelID,
            modelPath: modelDirectory?.path,
            reference: ref,
            candidate: cand,
            contexts: config.contexts,
            iterationCount: config.iterations,
            startedAt: now,
            endedAt: Date(),
            performance: nil,
            quality: quality,
            passFail: .passed(),
            failures: [],
            skipped: [],
            todos: []
        )
    }

    /// Architecture-aware admission-capacity metrics. These are the closest cheap
    /// equivalent of the live scheduler's post-load accounting: parse the model
    /// shape, estimate loaded weight bytes from local weight files, compute
    /// `kv_bytes_per_token` with `BatchScheduler.resolvedKVBytesPerToken`, then
    /// apply the same max-admitted-token formula used after model load.
    private static func liveCapacityMetrics(
        config: KVQuantGateConfig,
        modelDirectory: URL?
    ) -> [String: KVQuantMetricSummary] {
        guard let modelDirectory else { return [:] }
        let configURL = modelDirectory.appendingPathComponent("config.json")
        let architecture = KVEstimation.parseModelArchitecture(at: configURL)
        let weightBytes = localWeightBytes(in: modelDirectory)
        guard weightBytes > 0 else { return [:] }

        let refKV = BatchScheduler.resolvedKVBytesPerToken(
            architecture: architecture,
            weightBytes: weightBytes,
            quantScheme: engineScheme(for: config.reference)
        )
        let candKV = BatchScheduler.resolvedKVBytesPerToken(
            architecture: architecture,
            weightBytes: weightBytes,
            quantScheme: engineScheme(for: config.candidate)
        )
        let refBudget = maxAdmittedTokens(weightBytes: weightBytes, kvBytesPerToken: refKV)
        let candBudget = maxAdmittedTokens(weightBytes: weightBytes, kvBytesPerToken: candKV)

        return [
            "capacity.reference.kv_bytes_per_token": .init(unit: "bytes", samples: [Double(refKV)]),
            "capacity.candidate.kv_bytes_per_token": .init(unit: "bytes", samples: [Double(candKV)]),
            "capacity.live.kv_bytes_per_token_ratio_vs_reference": .init(unit: "ratio", samples: [Double(candKV) / Double(max(refKV, 1))]),
            "capacity.reference.max_admitted_tokens": .init(unit: "tokens", samples: [Double(refBudget)]),
            "capacity.candidate.max_admitted_tokens": .init(unit: "tokens", samples: [Double(candBudget)]),
            "capacity.live.max_admitted_tokens_ratio_vs_reference": .init(unit: "x", samples: [Double(candBudget) / Double(max(refBudget, 1))]),
            "capacity.weight_bytes_for_budget": .init(unit: "bytes", samples: [Double(weightBytes)]),
        ]
    }

    private static func engineScheme(for mode: KVQuantCandidateMode) -> KVQuantEngineScheme? {
        switch mode {
        case .fp16KV, .bf16KV, .fullVBF16, .affine4, .affine8, .fullVAffine4,
             .fullVTurbo4, .fullKVTurbo4, .turbo4v2:
            return nil
        case .k8v8g128:
            return KVQuantEngineScheme(candidateMode: .k8v8g128)
        case .k8v8g64:
            return KVQuantEngineScheme(candidateMode: .k8v8g64)
        case .k8v8g64Dequant:
            return KVQuantEngineScheme(candidateMode: .k8v8g64Dequant)
        case .k6v6g64:
            return KVQuantEngineScheme(candidateMode: .k6v6g64)
        case .k6v6g64Dequant:
            return KVQuantEngineScheme(candidateMode: .k6v6g64Dequant)
        }
    }

    private static func maxAdmittedTokens(weightBytes: Int, kvBytesPerToken: Int) -> Int {
        let totalMemory = Int(ProcessInfo.processInfo.physicalMemory)
        let osReserve = 4 * 1024 * 1024 * 1024
        let safetyMargin = totalMemory / 10
        let availableForKV = totalMemory - weightBytes - osReserve - safetyMargin
        guard availableForKV > 0, kvBytesPerToken > 0 else { return 1024 }
        return max(availableForKV / kvBytesPerToken, 1024)
    }

    private static func localWeightBytes(in modelDirectory: URL) -> Int {
        let weightExtensions: Set<String> = ["safetensors", "bin", "npz", "gguf"]
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: modelDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total = 0
        for case let url as URL in enumerator {
            guard weightExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let resolved = url.resolvingSymlinksInPath()
            guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += size
        }
        return total
    }

    private func runSuites(hardware: HardwareInfo, modelDirectory: URL?) async -> [KVQuantSuiteReport] {
        var reports: [KVQuantSuiteReport] = []
        for suite in config.suites {
            let report: KVQuantSuiteReport
            switch suite {
            case .performance, .memory:
                report = await performanceRunner.run(
                    config: config,
                    suite: suite,
                    hardware: hardware,
                    modelDirectory: modelDirectory
                )
            case .output:
                report = await outputSmokeRunner.run(
                    config: config,
                    hardware: hardware,
                    modelDirectory: modelDirectory
                )
            case .perplexity, .logits, .niah:
                report = await qualityRunner.run(
                    config: config,
                    suite: suite,
                    hardware: hardware,
                    modelDirectory: modelDirectory
                )
            case .capacity:
                report = Self.capacityReport(config: config, modelDirectory: modelDirectory)
            }
            reports.append(report)
        }
        return reports
    }
}
