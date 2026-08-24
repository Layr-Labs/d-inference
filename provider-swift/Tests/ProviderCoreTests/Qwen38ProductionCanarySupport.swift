// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLMCommon

@testable import ProviderCore

enum Qwen38ProductionCanary {
    static let targetModelID = "mlx-community/Qwen3.8-27B-4bit"
    static let assistantModelID = "mlx-community/Qwen3.8-27B-MTP-4bit"
    static let modelType = "qwen3_5"
    static let parityMaxTokens = 128
    static let mtpWarmupMaxTokens = 24
    static let parityRequestID = CBv2RequestID(0x5133_3800)
    static let warmupRequestID = CBv2RequestID(0x5133_3801)

    private static let liveGate = "DARKBLOOM_LIVE_MLX_TESTS"
    private static let qwenGate = "DARKBLOOM_LIVE_MLX_QWEN38"
    private static let mtpOnlyGate = "DARKBLOOM_LIVE_MLX_QWEN38_MTP_ONLY"
    private static let targetPathOverride = "DARKBLOOM_LIVE_MLX_QWEN38_MODEL_PATH"
    private static let assistantPathOverride = "DARKBLOOM_LIVE_MLX_QWEN38_MTP_PATH"
    private static let imagePathOverride = "DARKBLOOM_LIVE_MLX_QWEN38_IMAGE_PATH"
    private static let videoPathOverride = "DARKBLOOM_LIVE_MLX_QWEN38_VIDEO_PATH"

    static var enabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment[liveGate] == "1" && environment[qwenGate] == "1"
    }

    static var mtpOnly: Bool {
        ProcessInfo.processInfo.environment[mtpOnlyGate] == "1"
    }

    static var serialMTP: Bool {
        let raw = ProcessInfo.processInfo.environment["DARKBLOOM_QWEN_MTP_SERIAL"] ?? ""
        return ["1", "true", "yes", "on"].contains(raw.lowercased())
    }

    static func load() async throws -> Qwen38ProductionCanaryFixture {
        guard HardwareDetector.totalMemoryGB() >= 48 else {
            throw Qwen38ProductionCanaryError.insufficientMemory(HardwareDetector.totalMemoryGB())
        }
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw Qwen38ProductionCanaryError.missingMetallib
        }

        let environment = ProcessInfo.processInfo.environment
        let target = try resolveArtifact(
            override: environment[targetPathOverride], modelID: targetModelID)
        let assistant = try resolveArtifact(
            override: environment[assistantPathOverride], modelID: assistantModelID)
        let assistantLayerCount = try mtpLayerCount(assistant)
        guard assistantLayerCount == 1 else {
            throw Qwen38ProductionCanaryError.invalidAssistantLayerCount(
                assistant.path, assistantLayerCount)
        }
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let image = URL(
            fileURLWithPath: environment[imagePathOverride]
                ?? repositoryRoot.appendingPathComponent("libs/mlx/docs/logo/mlx_logo.png").path)
        let video = URL(
            fileURLWithPath: environment[videoPathOverride]
                ?? repositoryRoot.appendingPathComponent(
                    "libs/mlx-swift-lm/Tests/MLXLMTests/Resources/1080p_30.mov").path)
        guard FileManager.default.fileExists(atPath: image.path) else {
            throw Qwen38ProductionCanaryError.missingMedia(image.path)
        }
        guard FileManager.default.fileExists(atPath: video.path) else {
            throw Qwen38ProductionCanaryError.missingMedia(video.path)
        }
        guard ProviderLoop.modelIsVLM(at: target) else {
            throw Qwen38ProductionCanaryError.notVLM(target.path)
        }

        let stagedAssistant = try stageAssistant(from: assistant)
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 96 * 1024 * 1024 * 1024)
        let container: ModelContainer
        do {
            container = try await ModelContainerLoading.loadContainer(from: target)
        } catch {
            try? FileManager.default.removeItem(at: stagedAssistant)
            throw Qwen38ProductionCanaryError.stage(
                "ModelContainerLoading.loadContainer", String(reflecting: error))
        }
        let sizing = await SlotSizingSnapshot.build(
            container: container,
            modelPath: target,
            fallbackDefaultMaxTokens: 512)
        let tokenizer = await container.perform { TokenizerHandle($0.tokenizer) }
        return Qwen38ProductionCanaryFixture(
            modelDirectory: target,
            assistantDirectory: stagedAssistant,
            imageURL: image,
            videoURL: video,
            container: container,
            targetSizing: sizing,
            tokenizer: tokenizer,
            assistantLayerCount: assistantLayerCount)
    }

    static func resolveArtifact(override: String?, modelID: String) throws -> URL {
        if let override, !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw Qwen38ProductionCanaryError.missingArtifact(modelID, url.path)
            }
            return url
        }
        guard let url = ModelScanner.resolveLocalPath(modelID: modelID) else {
            throw Qwen38ProductionCanaryError.missingArtifact(modelID, "Hugging Face cache")
        }
        return url.standardizedFileURL
    }

    static func mtpLayerCount(_ artifact: URL) throws -> Int {
        let configURL = artifact.appendingPathComponent("config.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL))
        guard
            let config = object as? [String: Any],
            let textConfig = config["text_config"] as? [String: Any],
            let count = textConfig["mtp_num_hidden_layers"] as? Int
        else {
            throw Qwen38ProductionCanaryError.invalidAssistant(artifact.path)
        }
        return count
    }

    static func stageAssistant(from source: URL) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen38-mtp-canary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: source.path)
                .filter { $0 == "config.json" || $0.hasSuffix(".safetensors") }
                .sorted()
            guard names.contains("config.json"), names.contains(where: { $0.hasSuffix(".safetensors") }) else {
                throw Qwen38ProductionCanaryError.invalidAssistant(source.path)
            }
            for name in names {
                let resolved = source.appendingPathComponent(name).resolvingSymlinksInPath()
                let staged = destination.appendingPathComponent(name)
                do {
                    try FileManager.default.linkItem(at: resolved, to: staged)
                } catch {
                    // A cache mounted on another volume cannot be hard-linked.
                    // Foundation copyItem uses clonefile on APFS when possible,
                    // preserving the regular-file trust boundary without
                    // forcing a second physical copy of the large assistant.
                    try FileManager.default.copyItem(at: resolved, to: staged)
                }
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    static func rawTokens(
        bundle: ProviderEngineBundle,
        promptTokens: [Int],
        maxTokens: Int,
        requestID: CBv2RequestID
    ) async throws -> [Int] {
        let ownedEngine = await bundle.bridge.ownedEngine
        guard let engine = ownedEngine else {
            throw Qwen38ProductionCanaryError.engineUnavailable
        }
        let stream = try engine.submit(CBv2Request(
            id: requestID,
            promptTokens: promptTokens,
            sampling: CBv2SamplingParams(temperature: 0, topP: 1, topK: 0, minP: 0),
            maxTokens: maxTokens,
            stopTokens: await bundle.bridge.stopTokenIds,
            prefixCacheEnabled: false))
        var tokens: [Int] = []
        var terminal: CBv2FinishReason?
        for await event in stream {
            switch event {
            case .delta(_, let emitted, _): tokens.append(contentsOf: emitted)
            case .finished(let reason, _): terminal = reason
            }
        }
        guard !tokens.isEmpty else { throw Qwen38ProductionCanaryError.emptyGeneration }
        guard let terminal else { throw Qwen38ProductionCanaryError.missingTerminal }
        switch terminal {
        case .stop, .length: return tokens
        case .cancelled: throw Qwen38ProductionCanaryError.unexpectedTerminal("cancelled")
        case .error(let message): throw Qwen38ProductionCanaryError.unexpectedTerminal(message)
        case .terminal(let cause, let message):
            throw Qwen38ProductionCanaryError.unexpectedTerminal("\(cause): \(message)")
        }
    }

    static func timedRawTokens(
        bundle: ProviderEngineBundle,
        promptTokens: [Int],
        maxTokens: Int,
        requestID: CBv2RequestID
    ) async throws -> (tokens: [Int], seconds: Double) {
        let clock = ContinuousClock()
        let started = clock.now
        let tokens = try await rawTokens(
            bundle: bundle,
            promptTokens: promptTokens,
            maxTokens: maxTokens,
            requestID: requestID)
        let elapsed = started.duration(to: clock.now).components
        return (
            tokens,
            Double(elapsed.seconds)
                + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000)
    }

    static func waitForIdle(_ bridge: EngineV2Bridge) async throws -> CBv2CapacitySnapshot {
        for _ in 0..<200 {
            let snapshot = await bridge.capacitySnapshot()
            if snapshot.activeRequests == 0 && snapshot.waitingRequests == 0
                && snapshot.activeTokens == 0
            {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let snapshot = await bridge.capacitySnapshot()
        throw Qwen38ProductionCanaryError.capacityDidNotDrain(
            active: snapshot.activeRequests,
            waiting: snapshot.waitingRequests,
            tokens: snapshot.activeTokens)
    }

    static func retire(_ bundle: ProviderEngineBundle) async {
        await bundle.bridge.shutdown()
        bundle.releaseAssistant()
        MLX.Stream().synchronize()
        MLX.Memory.clearCache()
    }

    static func benchmarkDiagnostic(
        target: (tokens: [Int], seconds: Double),
        mtp: (tokens: [Int], seconds: Double),
        proposed: Int,
        accepted: Int
    ) -> String {
        let hardware = try? HardwareDetector.detect()
        let targetTPS = Double(target.tokens.count) / target.seconds
        let mtpTPS = Double(mtp.tokens.count) / mtp.seconds
        let acceptance = proposed > 0 ? Double(accepted) / Double(proposed) : 0
        return String(
            format:
                "QWEN38_CANARY chip=%@ ram_gb=%llu tokens=%d target_seconds=%.4f target_tps=%.3f mtp_seconds=%.4f mtp_tps=%.3f speedup=%.4fx mtp_acceptance=%.4f",
            locale: Locale(identifier: "en_US_POSIX"),
            hardware?.chipName ?? "unknown",
            hardware?.memoryGb ?? HardwareDetector.totalMemoryGB(),
            target.tokens.count,
            target.seconds,
            targetTPS,
            mtp.seconds,
            mtpTPS,
            target.seconds / mtp.seconds,
            acceptance)
    }
}

enum Qwen38ProductionCanaryError: Error, CustomStringConvertible {
    case missingArtifact(String, String)
    case invalidAssistant(String)
    case invalidAssistantLayerCount(String, Int)
    case missingMedia(String)
    case missingMetallib
    case insufficientMemory(UInt64)
    case notVLM(String)
    case engineUnavailable
    case emptyGeneration
    case missingTerminal
    case unexpectedTerminal(String)
    case capacityDidNotDrain(active: Int, waiting: Int, tokens: Int)
    case stage(String, String)

    var description: String {
        switch self {
        case .missingArtifact(let id, let path):
            "Qwen3.8 artifact \(id) is missing at \(path)"
        case .invalidAssistant(let path):
            "Qwen3.8 MTP artifact at \(path) lacks config.json or safetensors weights"
        case .invalidAssistantLayerCount(let path, let count):
            "Qwen3.8 MTP artifact at \(path) declares \(count) MTP layers; expected 1"
        case .missingMedia(let path):
            "Qwen3.8 canary media fixture is missing at \(path)"
        case .missingMetallib:
            "mlx.metallib is unavailable; run scripts/fetch-metallib.sh before the live canary"
        case .insufficientMemory(let memory):
            "Qwen3.8 canary requires at least 48 GiB unified memory; host reports \(memory) GiB"
        case .notVLM(let path):
            "Qwen3.8 artifact at \(path) does not declare vision_config"
        case .engineUnavailable:
            "production bundle released its EngineV2 before the canary submission"
        case .emptyGeneration:
            "production EngineV2 emitted no token IDs"
        case .missingTerminal:
            "production EngineV2 stream ended without a terminal event"
        case .unexpectedTerminal(let reason):
            "production EngineV2 ended unsuccessfully: \(reason)"
        case .capacityDidNotDrain(let active, let waiting, let tokens):
            "production EngineV2 capacity did not drain (active=\(active), waiting=\(waiting), tokens=\(tokens))"
        case .stage(let stage, let detail):
            "Qwen3.8 production canary failed during \(stage): \(detail)"
        }
    }
}
