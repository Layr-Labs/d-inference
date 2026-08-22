import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderBenchmark
@testable import ProviderCore

@Suite("Gemma 4 production MTP cached-model correctness", .serialized)
struct GemmaMTPProductionLiveTests {
    private static let redPNGDataURI =
        "data:image/png;base64,"
        + "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR42mO4IyJCEmIY"
        + "1TCqYfhqAAACcQQQFd0BdQAAAABJRU5ErkJggg=="

    @Test(
        "cached target and assistant load and bind",
        .enabled(
            if: MTPProductionLiveFixtures.enabled,
            MTPProductionLiveFixtures.disabledReason))
    func targetAndAssistantLoadAndBind() async throws {
        let bundle = try await MTPProductionLiveFixtures.loadBundle()
        #expect(bundle.targetFacts.modelType == "gemma4")
        #expect(bundle.assistantFacts.modelType == "gemma4_assistant")
        #expect(bundle.targetFacts.weightFileCount > 0)
        #expect(bundle.assistantFacts.weightFileCount > 0)
        MLX.Memory.clearCache()
    }

    @Test(
        "target-only and production MTP greedy token IDs are identical",
        .enabled(
            if: MTPProductionLiveFixtures.enabled,
            MTPProductionLiveFixtures.disabledReason))
    func targetOnlyAndMTPGreedyParity() async throws {
        let bundle = try await MTPProductionLiveFixtures.loadBundle()
        let fixed = try MTPBenchmarkMode.fixed(verificationWidth: 3)
        let report = try await MTPBenchmarkRunner.run(
            target: bundle.targetFacts,
            assistant: bundle.assistantFacts,
            hardware: try MTPBenchmarkModelFacts.hardware(),
            configuration: MTPBenchmarkConfiguration(
                prompts: try MTPProductionLiveFixtures.prompts(bundle: bundle),
                batchSizes: [1, 2],
                modes: [.targetOnly, fixed, .adaptive],
                maxTokensPerRow: 24,
                purpose: .productionCorrectness,
                stopPolicy: .production(tokenIDs: bundle.productionStopTokenIDs),
                deadline: .seconds(900)),
            sessions: bundle.makeSessionFactory())
        #expect(report.cases.filter { $0.mode.requestsMTP }.allSatisfy { $0.tokenParity })
        #expect(report.cases.filter { $0.mode.requestsMTP }.allSatisfy { $0.metrics.active })
        MLX.Memory.clearCache()
    }

    @Test(
        "assistant load failure leaves the production target bridge usable",
        .enabled(
            if: MTPProductionLiveFixtures.enabled,
            MTPProductionLiveFixtures.disabledReason))
    func assistantFailureFallsBackToTargetOnly() async throws {
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw MTPProductionLivePrerequisiteError.missingMetallib
        }
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 64 * 1024 * 1024 * 1024)
        let targetDirectory = try MTPProductionLiveFixtures.targetSnapshot()
        let assistantDirectory = try MTPProductionLiveFixtures.assistantSnapshot()
        let container = try await ModelContainerLoading.loadContainer(from: targetDirectory)
        let sizing = await SlotSizingSnapshot.build(
            container: container,
            modelPath: targetDirectory,
            fallbackDefaultMaxTokens: 32)
        let tokenizer = await container.perform { TokenizerHandle($0.tokenizer) }
        let localArtifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtp-live-loader-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: localArtifactDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localArtifactDirectory) }
        let assistantFiles = try FileManager.default.contentsOfDirectory(
            at: assistantDirectory,
            includingPropertiesForKeys: nil)
            .filter {
                $0.lastPathComponent == "config.json" || $0.pathExtension == "safetensors"
            }
        for source in assistantFiles {
            // Copy, never symlink: SpecDecStore.inspectLocalArtifact rejects
            // any symlinked member, which would fail the #require below
            // before the loader-failure fallback under test ever runs.
            try FileManager.default.copyItem(
                at: source.resolvingSymlinksInPath(),
                to: localArtifactDirectory.appendingPathComponent(source.lastPathComponent))
        }
        let artifact = try #require(
            SpecDecStore.inspectLocalArtifact(path: localArtifactDirectory.path))
        let preparation = SpecDecPreparation(
            artifact: artifact,
            status: .candidate(artifact))
        let prepared = try await EngineV2SlotFactory.prepareProductionModel(
            modelId: MTPProductionLiveFixtures.targetID,
            isVLM: true,
            container: container,
            specDecPreparation: preparation,
            assistantLoader: AlwaysFailMTPAssistantLoader())
        #expect(prepared.assistant == nil)
        #expect(prepared.mtpStatus.reason == .assistantLoadFailed)

        let grant = Int(min(
            UnifiedMemoryCap.kvBudgetBytes(
                physicalBytes: ProcessInfo.processInfo.physicalMemory,
                residentWeightBytes: UInt64(max(0, sizing.weightsBytes)),
                configReserveBytes: 0),
            UInt64(Int.max)))
        let bundle = try await EngineV2SlotFactory.makeProductionBundle(
            modelId: MTPProductionLiveFixtures.targetID,
            modelType: "gemma4",
            isVLM: true,
            modelDirectory: targetDirectory,
            container: container,
            tokenizer: tokenizer,
            sizing: sizing,
            kvBytesCapacity: grant,
            maxConcurrentRequests: 1,
            kvBudget: nil,
            specDecPreparation: preparation,
            preparedModel: prepared,
            environment: ["DARKBLOOM_PREFIX_CACHE": "0"])
        let status = await bundle.bridge.mtpStatusSnapshot()
        #expect(status.configured)
        #expect(!status.active)
        #expect(status.fallbackReason == .assistantLoadFailed)

        let prompt = "What is 9 plus 4? Reply with only the number."
        let tokens: [Int] = try await container.perform { context in
            try context.tokenizer.applyChatTemplate(
                messages: [["role": "user", "content": prompt]],
                tools: nil,
                additionalContext: nil)
        }
        let result = await collect(
            from: bundle.bridge,
            promptTokens: tokens,
            request: ChatCompletionRequest(
                model: MTPProductionLiveFixtures.targetID,
                messages: [ChatMessage(role: "user", content: prompt)],
                temperature: 0,
                max_tokens: 32))
        await bundle.bridge.shutdown()
        MLX.Memory.clearCache()
        #expect(!result.didError, "target-only fallback failed: \(result.error ?? "")")
        #expect(result.info != nil)
        #expect(result.fullText.contains("13"))
    }

    @Test(
        "shared VLM text tower and tool-templated decode retain greedy parity",
        .enabled(
            if: MTPProductionLiveFixtures.enabled,
            MTPProductionLiveFixtures.disabledReason))
    func vlmToolPathParity() async throws {
        let bundle = try await MTPProductionLiveFixtures.loadBundle()
        let fixed = try MTPBenchmarkMode.fixed(verificationWidth: 3)
        let report = try await MTPBenchmarkRunner.run(
            target: bundle.targetFacts,
            assistant: bundle.assistantFacts,
            hardware: try MTPBenchmarkModelFacts.hardware(),
            configuration: MTPBenchmarkConfiguration(
                prompts: [try MTPProductionLiveFixtures.toolPrompt(bundle: bundle)],
                batchSizes: [1],
                modes: [.targetOnly, fixed],
                maxTokensPerRow: 64,
                purpose: .productionCorrectness,
                stopPolicy: .production(tokenIDs: bundle.productionStopTokenIDs),
                deadline: .seconds(600)),
            sessions: bundle.makeSessionFactory())
        let candidate = try #require(report.cases.last)
        #expect(candidate.tokenParity)
        #expect(candidate.metrics.active)
        #expect(candidate.metrics.proposedTokens > 0)
        #expect(candidate.metrics.rounds > 0)
        #expect(candidate.rows.allSatisfy { $0.tokenCount > 0 })
        #expect(report.stopPolicy.configuredTokenCount == bundle.productionStopTokenIDs.count)
        MLX.Memory.clearCache()
    }

    @Test(
        "VLM image-prefill decode retains greedy token parity",
        .enabled(
            if: MTPProductionLiveFixtures.enabled,
            MTPProductionLiveFixtures.disabledReason))
    func vlmImagePathParity() async throws {
        let bundle = try await MTPProductionLiveFixtures.loadBundle()
        let request = OpenAIChatCompletionRequest(
            model: MTPProductionLiveFixtures.targetID,
            messages: [OpenAIChatMessage(
                role: .user,
                content: .parts([
                    .text("What color is this image? Reply with one word."),
                    .imageURL(Self.redPNGDataURI),
                ]))],
            temperature: 0,
            maxTokens: 16)
        let prepared = try await EngineV2VisionPrefill.prepare(
            container: bundle.targetContainer,
            request: request)
        let factory = bundle.makeSessionFactory()

        let targetSession = try await factory.make(.targetOnly, 1)
        let baseline = try await rawTokens(
            engine: targetSession.engine,
            promptTokens: prepared.promptTokens,
            maxTokens: 16,
            stopTokens: bundle.productionStopTokenIDs,
            multimodal: prepared.multimodalInput())
        await targetSession.engine.shutdown()

        let fixed = try MTPBenchmarkMode.fixed(verificationWidth: 3)
        let mtpSession = try await factory.make(fixed, 1)
        let candidate = try await rawTokens(
            engine: mtpSession.engine,
            promptTokens: prepared.promptTokens,
            maxTokens: 16,
            stopTokens: bundle.productionStopTokenIDs,
            multimodal: prepared.multimodalInput())
        let metrics = await mtpSession.metrics()
        await mtpSession.engine.shutdown()

        #expect(metrics.active)
        if candidate != baseline {
            Issue.record("MTP image parity failed for row 0")
        }
        MLX.Memory.clearCache()
    }

    private func rawTokens(
        engine: any CBv2Engine,
        promptTokens: [Int],
        maxTokens: Int,
        stopTokens: Set<Int>,
        multimodal: CBv2MultimodalInput
    ) async throws -> [Int] {
        let stream = try engine.submit(CBv2Request(
            id: CBv2RequestID(1),
            promptTokens: promptTokens,
            sampling: CBv2SamplingParams(temperature: 0),
            maxTokens: maxTokens,
            stopTokens: stopTokens,
            multimodal: multimodal))
        var tokens: [Int] = []
        var finishReason: CBv2FinishReason?
        for await event in stream {
            switch event {
            case .delta(_, let emitted, _): tokens.append(contentsOf: emitted)
            case .finished(let reason, _): finishReason = reason
            }
        }
        guard let finishReason else {
            throw MTPBenchmarkError.missingTerminalEvent(row: 0)
        }
        switch finishReason {
        case .stop:
            guard let finalToken = tokens.last, stopTokens.contains(finalToken) else {
                throw MTPBenchmarkError.unexpectedTerminal(
                    row: 0,
                    condition: "production stop membership")
            }
        case .length:
            break
        case .cancelled:
            throw MTPBenchmarkError.unsuccessfulTerminal(
                row: 0, reason: "cancelled")
        case .error:
            throw MTPBenchmarkError.unsuccessfulTerminal(
                row: 0, reason: "engine_error")
        case .terminal(let cause, _):
            throw MTPBenchmarkError.unsuccessfulTerminal(
                row: 0, reason: "terminal_\(cause)")
        }
        guard !tokens.isEmpty else { throw MTPBenchmarkError.emptyTokenStream(row: 0) }
        return tokens
    }
}

private struct AlwaysFailMTPAssistantLoader: ProviderMTPAssistantLoading {
    func loadAndBind(
        artifact _: SpecDecArtifact,
        target _: any MLXLMCommon.LanguageModel
    ) async throws -> ProviderMTPAssistantHandle {
        throw ProviderMTPAssistantLoadError.loadFailed("injected live fallback probe")
    }
}
