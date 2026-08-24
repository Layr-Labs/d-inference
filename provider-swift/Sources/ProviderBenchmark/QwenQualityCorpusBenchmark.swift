import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import ProviderCore

/// Real-model Qwen quality harness. It loads one container and constructs one
/// engine through the serving factory entry point, then executes every
/// corpus case sequentially on that engine.
public enum QwenQualityCorpusBenchmark {
    public static let defaultMaximumTokens = 64
    public static let defaultRunLabel = "unlabeled"

    private static let warmupRequestID: UInt64 = 0x5157_0000
    private static let measuredRequestIDBase: UInt64 = 0x5157_1000

    private struct ModelDescriptor: Sendable {
        let modelType: String
        let architecture: String?
        let isVLM: Bool
    }

    private struct EngineComponents: Sendable {
        let engine: any CBv2Engine
        let preparedCases: [QwenQualityPreparedCase]
        let resolvedKVBackend: String
    }

    public static func run(
        modelID: String,
        modelDirectory: URL,
        corpusURL: URL,
        maximumTokens: Int = defaultMaximumTokens,
        runLabel: String = defaultRunLabel,
        baselineReportURL: URL? = nil,
        kvBackend: EngineV2KVBackendSelection = .auto,
        hardware: HardwareInfo
    ) async throws -> QwenQualityCorpusReport {
        let label = runLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.utf8.count <= 128 else {
            throw QwenQualityCorpusBenchmarkError.invalidRunLabel
        }
        guard (QwenQualityCorpusExecutor.minimumGenerationTokens
            ... QwenQualityCorpusExecutor.maximumGenerationTokens)
            .contains(maximumTokens)
        else {
            throw QwenQualityCorpusExecutionError.invalidGenerationWindow(
                actual: maximumTokens,
                minimum: QwenQualityCorpusExecutor.minimumGenerationTokens,
                maximum: QwenQualityCorpusExecutor.maximumGenerationTokens)
        }

        let modelDirectory = modelDirectory.resolvingSymlinksInPath().standardizedFileURL
        let loadedCorpus = try QwenQualityCorpusLoader.load(from: corpusURL)
        let baseline: QwenQualityCorpusReport?
        if let baselineReportURL {
            baseline = try QwenQualityCorpusReport.load(from: baselineReportURL)
        } else {
            baseline = nil
        }
        let processEnvironment = ProcessInfo.processInfo.environment
        let policyEnvironment = capturedPolicyEnvironment(processEnvironment)

        log("hashing fixed model artifact \(modelID)")
        guard let fingerprintBefore = WeightHasher.snapshotFingerprint(
            snapshotDir: modelDirectory)
        else {
            throw QwenQualityCorpusBenchmarkError.modelFingerprintUnavailable
        }
        guard let artifactSHA256 = WeightHasher.computeHash(
            snapshotDir: modelDirectory,
            modelID: modelID)
        else {
            throw QwenQualityCorpusBenchmarkError.modelHashUnavailable
        }
        guard WeightHasher.snapshotFingerprint(snapshotDir: modelDirectory)
            == fingerprintBefore
        else {
            throw QwenQualityCorpusBenchmarkError.modelArtifactChangedDuringRun
        }

        // Inspect only after the hash window is proven stable. Otherwise a
        // config edit between inspection and hashing could make the report's
        // model descriptor disagree with the artifact actually loaded.
        let descriptor = try inspectModel(at: modelDirectory)
        guard descriptor.modelType.lowercased().contains("qwen")
            || descriptor.architecture?.lowercased().contains("qwen") == true
        else {
            throw QwenQualityCorpusBenchmarkError.notQwen(
                modelType: descriptor.modelType,
                architecture: descriptor.architecture)
        }
        guard WeightHasher.snapshotFingerprint(snapshotDir: modelDirectory)
            == fingerprintBefore
        else {
            throw QwenQualityCorpusBenchmarkError.modelArtifactChangedDuringRun
        }

        log("loading model \(modelID) once")
        log("  path: \(modelDirectory.path)")
        let container: ModelContainer
        if descriptor.isVLM {
            container = try await VLMModelFactory.shared.loadContainer(
                from: modelDirectory,
                using: LocalTokenizerLoader())
        } else {
            container = try await LLMModelFactory.shared.loadContainer(
                from: modelDirectory,
                using: LocalTokenizerLoader())
        }

        let sizing = await SlotSizingSnapshot.build(
            container: container,
            modelPath: modelDirectory,
            fallbackDefaultMaxTokens: maximumTokens)
        let kvCapacity = Int(min(
            UnifiedMemoryCap.kvBudgetBytes(
                physicalBytes: ProcessInfo.processInfo.physicalMemory,
                residentWeightBytes: UInt64(max(0, sizing.weightsBytes)),
                configReserveBytes: 0),
            UInt64(Int.max)))
        let qualityPrefixCache: (any CBv2PrefixCache)? =
            processEnvironment["DARKBLOOM_QUALITY_CANONICAL_EXACT_PREFILL"] == "1"
            ? ExactPrefixCacheV2(config: .init(
                modelIdentity: "quality-canonical:\(artifactSHA256)",
                policyIdentity: "quality-canonical-exact-prefill-v1",
                maxBytes: 1))
            : nil
        let components = try await container.perform { context -> EngineComponents in
            let preparedCases = try QwenQualityCorpusExecutor.prepare(
                corpus: loadedCorpus.corpus,
                maximumTokens: maximumTokens,
                maximumContextTokens: sizing.maxContextLength > 0
                    ? sizing.maxContextLength : nil,
                tokenizer: context.tokenizer)
            let servingModel = try EngineV2Factory.benchmarkServingModel(
                model: context.model,
                isVLM: descriptor.isVLM,
                modelDirectory: modelDirectory,
                environment: processEnvironment)
            let build = try EngineV2Factory.makeProductionBuild( // pragma: allowlist secret
                model: servingModel,
                tokenizer: context.tokenizer,
                kvBytesCapacity: kvCapacity,
                maxConcurrentRequests: 1,
                prefixCache: qualityPrefixCache,
                kvBackend: kvBackend,
                maxContextLength: sizing.maxContextLength > 0
                    ? sizing.maxContextLength : nil,
                environment: processEnvironment)
            return EngineComponents(
                engine: build.engine,
                preparedCases: preparedCases,
                resolvedKVBackend: build.resolvedKVBackendDescriptor)
        }
        log("engine resolved KV backend \(components.resolvedKVBackend)")

        let caseResults: [QwenQualityCorpusReport.CaseResult]
        do {
            // Warm the exact engine/model/tokenizer stack without constructing
            // a second engine. Prefix caching is absent, so the measured first
            // case still performs its full prompt forward.
            log("warming one-token decode on the serving engine")
            _ = try await QwenQualityCorpusEngineRunner.run(
                engine: components.engine,
                prepared: components.preparedCases[0],
                maximumTokens: 1,
                requestID: CBv2RequestID(warmupRequestID))

            var measured: [QwenQualityCorpusReport.CaseResult] = []
            measured.reserveCapacity(components.preparedCases.count)
            for (index, prepared) in components.preparedCases.enumerated() {
                log("case \(index + 1)/\(components.preparedCases.count): "
                    + prepared.corpusCase.id)
                let (requestID, overflow) = measuredRequestIDBase.addingReportingOverflow(
                    UInt64(index))
                guard !overflow else {
                    throw QwenQualityCorpusExecutionError.requestIDOverflow
                }
                measured.append(try await QwenQualityCorpusEngineRunner.run(
                    engine: components.engine,
                    prepared: prepared,
                    maximumTokens: maximumTokens,
                    requestID: CBv2RequestID(requestID)))
            }
            caseResults = measured
        } catch {
            await stopAndSynchronize(components.engine)
            throw error
        }
        await stopAndSynchronize(components.engine)

        guard WeightHasher.snapshotFingerprint(snapshotDir: modelDirectory)
            == fingerprintBefore
        else {
            throw QwenQualityCorpusBenchmarkError.modelArtifactChangedDuringRun
        }

        let report = QwenQualityCorpusReport(
            run: .init(
                label: label,
                createdAtUTC: timestamp()),
            model: .init(
                id: modelID,
                path: modelDirectory.path,
                artifactSHA256: artifactSHA256,
                modelType: descriptor.modelType,
                architecture: descriptor.architecture,
                maximumContextTokens: sizing.maxContextLength > 0
                    ? sizing.maxContextLength : nil),
            corpus: .init(
                id: loadedCorpus.corpus.id,
                version: loadedCorpus.corpus.version,
                path: loadedCorpus.path,
                sha256: loadedCorpus.sha256,
                caseCount: loadedCorpus.corpus.cases.count,
                license: loadedCorpus.corpus.license,
                provenance: loadedCorpus.corpus.provenance),
            hardware: .init(
                machineModel: hardware.machineModel,
                chipName: hardware.chipName,
                memoryGB: hardware.memoryGb,
                gpuCores: hardware.gpuCores),
            engine: .init(
                factory: "EngineV2Factory.makeProductionBuild", // pragma: allowlist secret
                kvBackendSelection: kvBackend.rawValue,
                resolvedKVBackend: components.resolvedKVBackend,
                maxConcurrentRequests: 1,
                requestsExecutedSequentially: true,
                prefixCacheEnabled: false,
                warmupPerformed: true,
                policyEnvironment: policyEnvironment),
            generation: .init(
                temperature: 0,
                topP: 1,
                topK: 0,
                maximumTokens: maximumTokens,
                minimumRequiredTokens:
                    QwenQualityCorpusExecutor.minimumGenerationTokens,
                stopPolicy: "fixed-length-no-stop-tokens"),
            cases: caseResults)
        try report.validate()

        guard let baseline else { return report }
        return report.addingComparison(try QwenQualityCorpusComparison.compare(
            baseline: baseline,
            candidate: report))
    }

    private static func inspectModel(at directory: URL) throws -> ModelDescriptor {
        let configURL = directory.appendingPathComponent("config.json")
        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            throw QwenQualityCorpusBenchmarkError.invalidModelConfig(
                "could not read \(configURL.path): \(error)")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw QwenQualityCorpusBenchmarkError.invalidModelConfig(
                "config.json must contain a JSON object")
        }
        let textConfig = object["text_config"] as? [String: Any]
        guard let modelType = (object["model_type"] as? String)
            ?? (textConfig?["model_type"] as? String),
            !modelType.isEmpty
        else {
            throw QwenQualityCorpusBenchmarkError.invalidModelConfig(
                "config.json is missing model_type")
        }
        let architecture = (object["architectures"] as? [String])?.first
            ?? (textConfig?["architectures"] as? [String])?.first
        return ModelDescriptor(
            modelType: modelType,
            architecture: architecture,
            isVLM: object["vision_config"] != nil)
    }

    /// Capture only experiment-policy keys. Never serialize the whole process
    /// environment: benchmark reports must not become credential dumps.
    static func capturedPolicyEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        let cbv2PrefillKeys: Set<String> = [
            "DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS",
            "DARKBLOOM_CBV2_MIXED_PREFILL_CAP",
            "DARKBLOOM_CBV2_PREFILL_CHUNK",
            "DARKBLOOM_CBV2_PREFILL_NARROWING",
            "DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE",
            "DARKBLOOM_QUALITY_CANONICAL_EXACT_PREFILL",
        ]
        return environment.filter { key, _ in
            key.hasPrefix("DARKBLOOM_QWEN35_PREFILL_")
                || cbv2PrefillKeys.contains(key)
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func stopAndSynchronize(_ engine: any CBv2Engine) async {
        await engine.shutdown()
        Stream().synchronize()
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[quality-corpus] \(message)\n".utf8))
    }
}

public enum QwenQualityCorpusBenchmarkError:
    Error, Equatable, CustomStringConvertible
{
    case invalidRunLabel
    case invalidModelConfig(String)
    case notQwen(modelType: String, architecture: String?)
    case modelHashUnavailable
    case modelFingerprintUnavailable
    case modelArtifactChangedDuringRun

    public var description: String {
        switch self {
        case .invalidRunLabel:
            return "quality run label must contain 1...128 UTF-8 bytes"
        case .invalidModelConfig(let message):
            return "quality benchmark model config is invalid: \(message)"
        case .notQwen(let modelType, let architecture):
            return "quality corpus mode requires a Qwen checkpoint "
                + "(model_type=\(modelType), architecture=\(architecture ?? "unknown"))"
        case .modelHashUnavailable:
            return "quality benchmark could not compute the model artifact SHA-256"
        case .modelFingerprintUnavailable:
            return "quality benchmark could not fingerprint the model artifact"
        case .modelArtifactChangedDuringRun:
            return "quality benchmark model artifact changed while the run was in progress"
        }
    }
}
