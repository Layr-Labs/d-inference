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
        let metrics: [String: KVQuantMetricSummary] = [
            "capacity.kv_bytes_per_token_per_elem": .init(unit: "bytes", samples: [cand.effectiveKVBytesPerTokenPerElem]),
            "capacity.reference_kv_bytes_per_token_per_elem": .init(unit: "bytes", samples: [ref.effectiveKVBytesPerTokenPerElem]),
            "capacity.kv_token_ratio_vs_fp16": .init(unit: "x", samples: [cand.capacityRatioVsFP16]),
            "capacity.stored_bits_k": .init(unit: "bits", samples: [Double(cand.storedBitsK)]),
            "capacity.stored_bits_v": .init(unit: "bits", samples: [Double(cand.storedBitsV)]),
        ]
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
