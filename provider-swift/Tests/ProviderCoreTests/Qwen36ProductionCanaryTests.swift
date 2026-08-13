// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Qwen3.6 production artifact canary", .serialized)
struct Qwen36ProductionCanaryTests {
    @Test(
        "combined VLM and inline MTP serve through the production bundle",
        .enabled(
            if: Qwen36ProductionCanary.enabled,
            "set DARKBLOOM_LIVE_MLX_TESTS=1 and DARKBLOOM_LIVE_MLX_QWEN36=1 to run the local real-artifact Qwen3.6 production canary")
    )
    func combinedVLMAndInlineMTPProductionBundle() async throws {
        let fixture = try await Qwen36ProductionCanary.load()
        var liveBundle: ProviderEngineBundle?

        do {
            let targetBundle: ProviderEngineBundle
            do {
                targetBundle = try await fixture.makeBundle(
                    preparation: .init(
                        artifact: nil,
                        status: .disabled(.configDisabled, configured: false)))
            } catch {
                throw Qwen36ProductionCanaryError.stage(
                    "target-only EngineV2SlotFactory production bundle",
                    String(reflecting: error))
            }
            liveBundle = targetBundle
            let targetStatus = await targetBundle.bridge.mtpStatusSnapshot()
            #expect(!targetStatus.configured)
            #expect(!targetStatus.active)

            let scheduler = fixture.scheduler(bundle: targetBundle)
            let text: Qwen36ProductionCanaryServerResult
            do {
                text = try await Qwen36ProductionCanary.collect(
                    scheduler,
                    request: fixture.textRequest())
            } catch {
                throw Qwen36ProductionCanaryError.stage(
                    "target-only scheduler text request", String(reflecting: error))
            }
            #expect(text.text.trimmingCharacters(in: .whitespacesAndNewlines)
                == #"{"sum":423,"check":"ok"}"#)
            let textUsage = try #require(text.info, "text canary emitted no terminal usage")
            #expect(textUsage.promptTokens > 0)
            #expect(textUsage.completionTokens > 0)

            let visionProbe = Qwen36ProductionCanaryVisionProbe()
            let visionScheduler = fixture.scheduler(
                bundle: targetBundle,
                vision: EngineV2VisionPlumbing(
                    prepare: { container, request, reasoningEffort in
                        let prepared = try await EngineV2VisionPrefill.prepare(
                            container: container,
                            request: request,
                            reasoningEffort: reasoningEffort)
                        visionProbe.recordPrepared(spanCount: prepared.spans.count)
                        return prepared
                    },
                    emitTelemetry: { _ in visionProbe.recordRefusal() }))
            let stepsBeforeVision = await targetBundle.bridge.capacitySnapshot().stepsExecuted
            let vision: Qwen36ProductionCanaryServerResult
            do {
                vision = try await Qwen36ProductionCanary.collect(
                    visionScheduler,
                    request: try fixture.imageRequest())
            } catch {
                throw Qwen36ProductionCanaryError.stage(
                    "target-only scheduler EngineV2VisionPrefill image request",
                    String(reflecting: error))
            }
            #expect(vision.text.contains("ORCHID-7319"))
            #expect(vision.text.contains("27"))
            #expect(vision.text.contains("CYAN TRIANGLE"))
            #expect(visionProbe.preparedCount == 1)
            #expect(visionProbe.lastSpanCount > 0)
            #expect(visionProbe.refusalCount == 0)
            let visionUsage = try #require(vision.info, "image canary emitted no terminal usage")
            #expect(visionUsage.promptTokens > 0)
            #expect(visionUsage.completionTokens > 0)
            let stepsAfterVision = await targetBundle.bridge.capacitySnapshot().stepsExecuted
            #expect(stepsAfterVision > stepsBeforeVision, "vision request never entered EngineV2")

            let tool = try await Qwen36ProductionCanary.collect(
                scheduler,
                request: fixture.toolRequest())
            let toolCall = try #require(tool.toolCalls.first, "Qwen emitted no parsed tool call")
            #expect(tool.toolCalls.count == 1)
            #expect(toolCall.function.name == "record_canary")
            #expect(toolCall.function.arguments["code"] == .string("ORCHID-7319"))
            #expect(toolCall.function.arguments["count"] == .int(27))

            async let alpha = Qwen36ProductionCanary.collect(
                scheduler,
                request: fixture.concurrentRequest(
                    messages: [
                        .init(role: .system, content: .text("Obey the requested exact output.")),
                        .init(role: .user, content: .text("Reply exactly ALPHA-17")),
                    ]))
            async let beta = Qwen36ProductionCanary.collect(
                scheduler,
                request: fixture.concurrentRequest(
                    messages: [
                        .init(role: .system, content: .text("Obey the requested exact output.")),
                        .init(role: .user, content: .text("Remember BETA but do not answer yet.")),
                        .init(role: .assistant, content: .text("Understood.")),
                        .init(role: .user, content: .text("Reply exactly BETA-29")),
                    ]))
            let (alphaResult, betaResult) = try await (alpha, beta)
            #expect(alphaResult.text.trimmingCharacters(in: .whitespacesAndNewlines) == "ALPHA-17")
            #expect(betaResult.text.trimmingCharacters(in: .whitespacesAndNewlines) == "BETA-29")
            #expect(alphaResult.info?.completionTokens ?? 0 > 0)
            #expect(betaResult.info?.completionTokens ?? 0 > 0)
            _ = try await Qwen36ProductionCanary.waitForIdle(targetBundle.bridge)

            let parityPrompt = try fixture.tokenize(fixture.parityRequest())
            let targetTokens = try await Qwen36ProductionCanary.rawTokens(
                bundle: targetBundle,
                promptTokens: parityPrompt,
                maxTokens: Qwen36ProductionCanary.parityMaxTokens)
            #expect(targetTokens.count > 32, "parity prompt did not exercise a long decode")

            await Qwen36ProductionCanary.retire(targetBundle)
            liveBundle = nil

            let inlinePreparation = await fixture.inlinePreparation()
            let artifact = try #require(
                inlinePreparation.artifact,
                "SpecDecArtifactFunnel did not resolve the inline MTP payload")
            #expect(artifact.source == .inline)
            #expect(inlinePreparation.status.source == .inline)
            #expect(inlinePreparation.status.configured)
            #expect(artifact.directory == fixture.modelDirectory.standardizedFileURL)

            let mtpBundle = try await fixture.makeBundle(preparation: inlinePreparation)
            liveBundle = mtpBundle
            let initialMTP = await mtpBundle.bridge.mtpStatusSnapshot()
            #expect(initialMTP.configured)
            #expect(initialMTP.active)
            #expect(initialMTP.assistantSource == .inline)
            #expect(initialMTP.assistantResidentBytes > 0)
            #expect(mtpBundle.assistantBytes > 0)
            #expect(
                await mtpBundle.bridge.kvBytesPerToken
                    == fixture.targetSizing.fp16KVBytesPerToken + 2_048)

            let mtpTokens = try await Qwen36ProductionCanary.rawTokens(
                bundle: mtpBundle,
                promptTokens: parityPrompt,
                maxTokens: Qwen36ProductionCanary.parityMaxTokens)
            #expect(mtpTokens == targetTokens, "MTP changed greedy emitted token IDs")
            let mtp = await mtpBundle.bridge.mtpStatusSnapshot()
            #expect(mtp.active)
            #expect(mtp.proposedTokens > 0)
            #expect(mtp.acceptedDraftTokens > 0)
            #expect(mtp.proposedTokens > mtp.acceptedDraftTokens, "parity run exercised no rejection")
            #expect(mtp.serialVerificationRounds > 0)
            #expect(mtp.rectangularVerificationRounds == 0)
            #expect(mtp.rounds > 0)

            let cancellation = try await fixture.cancelAfterFirstDelta(bundle: mtpBundle)
            #expect(cancellation.sawDelta)
            #expect(cancellation.error == "request cancelled")
            #expect(cancellation.promptTokens > 0)
            let drained = try await Qwen36ProductionCanary.waitForIdle(mtpBundle.bridge)
            #expect(drained.activeRequests == 0)
            #expect(drained.waitingRequests == 0)
            #expect(drained.activeTokens == 0)
            #expect(drained.kvBytesInUse == 0, "recurrent/KV request state remained charged")
            #expect(drained.kvBytesReserved == 0, "request reservation remained charged")
            let drainedSlot = await mtpBundle.bridge.backendSlotCapacity()
            #expect(drainedSlot.numRunning == 0)
            #expect(drainedSlot.numWaiting == 0)
            #expect(drainedSlot.activeTokenBudgetUsed == 0)
            #expect(drainedSlot.maxTokensPotential == 0)

            await Qwen36ProductionCanary.retire(mtpBundle)
            liveBundle = nil
        } catch {
            if let liveBundle {
                await Qwen36ProductionCanary.retire(liveBundle)
            }
            throw error
        }
    }
}

private enum Qwen36ProductionCanary {
    static let modelID = "qwen3.6-35b-a3b-vl-mtp-production-canary"
    static let modelType = "qwen3_5_moe"
    static let parityMaxTokens = 192

    private static let liveGate = "DARKBLOOM_LIVE_MLX_TESTS"
    private static let qwenGate = "DARKBLOOM_LIVE_MLX_QWEN36"
    private static let modelPathOverride = "DARKBLOOM_LIVE_MLX_QWEN36_MODEL_PATH"
    private static let imagePathOverride = "DARKBLOOM_LIVE_MLX_QWEN36_IMAGE_PATH"
    private static let defaultModelPath =
        "/var/folders/hv/5779vnmn5c564l3tdknlf4x80000gp/T/opencode/"
        + "Qwen3.6-35B-A3B-MLX-VL-4bit-g64-router8-mtp-work"
    private static let defaultImagePath =
        "/var/folders/hv/5779vnmn5c564l3tdknlf4x80000gp/T/opencode/qwen36-vlm-proof.png"

    static var enabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment[liveGate] == "1" && environment[qwenGate] == "1"
    }

    static func load() async throws -> Qwen36ProductionCanaryFixture {
        let environment = ProcessInfo.processInfo.environment
        let modelDirectory = URL(
            fileURLWithPath: environment[modelPathOverride] ?? defaultModelPath,
            isDirectory: true).standardizedFileURL
        let imageURL = URL(
            fileURLWithPath: environment[imagePathOverride] ?? defaultImagePath,
            isDirectory: false).standardizedFileURL
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
            throw Qwen36ProductionCanaryError.missingArtifact(modelDirectory.path)
        }
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            throw Qwen36ProductionCanaryError.missingImage(imageURL.path)
        }
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw Qwen36ProductionCanaryError.missingMetallib
        }

        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 96 * 1024 * 1024 * 1024)
        let container: ModelContainer
        do {
            container = try await ModelContainerLoading.loadContainer(from: modelDirectory)
        } catch {
            throw Qwen36ProductionCanaryError.stage(
                "ModelContainerLoading.loadContainer", String(reflecting: error))
        }
        guard ProviderLoop.modelIsVLM(at: modelDirectory) else {
            throw Qwen36ProductionCanaryError.notVLM(modelDirectory.path)
        }
        let sizing = await SlotSizingSnapshot.build(
            container: container,
            modelPath: modelDirectory,
            fallbackDefaultMaxTokens: 512)
        let tokenizer = await container.perform { TokenizerHandle($0.tokenizer) }
        return Qwen36ProductionCanaryFixture(
            modelDirectory: modelDirectory,
            imageURL: imageURL,
            container: container,
            targetSizing: sizing,
            tokenizer: tokenizer)
    }

    static func collect(
        _ engine: MultiModelBatchSchedulerEngine,
        request: OpenAIChatCompletionRequest
    ) async throws -> Qwen36ProductionCanaryServerResult {
        let stream = try await engine.streamChatCompletion(request: request)
        var result = Qwen36ProductionCanaryServerResult()
        for try await event in stream {
            switch event {
            case .content(let text):
                result.text += text
            case .toolCall(let call):
                result.toolCalls.append(call)
            case .info(let info):
                result.info = info
            }
        }
        return result
    }

    static func rawTokens(
        bundle: ProviderEngineBundle,
        promptTokens: [Int],
        maxTokens: Int
    ) async throws -> [Int] {
        let ownedEngine = await bundle.bridge.ownedEngine
        guard let engine = ownedEngine else {
            throw Qwen36ProductionCanaryError.engineUnavailable
        }
        let stopTokens = await bundle.bridge.stopTokenIds
        let stream = try engine.submit(CBv2Request(
            id: CBv2RequestID(0x5133_3600),
            promptTokens: promptTokens,
            sampling: CBv2SamplingParams(
                temperature: 0,
                topP: 1,
                topK: 0,
                minP: 0),
            maxTokens: maxTokens,
            stopTokens: stopTokens,
            prefixCacheEnabled: false))
        var tokens: [Int] = []
        var terminal: CBv2FinishReason?
        for await event in stream {
            switch event {
            case .delta(_, let emitted, _):
                tokens.append(contentsOf: emitted)
            case .finished(let reason, _):
                terminal = reason
            }
        }
        guard !tokens.isEmpty else { throw Qwen36ProductionCanaryError.emptyGeneration }
        guard let terminal else { throw Qwen36ProductionCanaryError.missingTerminal }
        switch terminal {
        case .stop, .length:
            return tokens
        case .cancelled:
            throw Qwen36ProductionCanaryError.unexpectedTerminal("cancelled")
        case .error(let message):
            throw Qwen36ProductionCanaryError.unexpectedTerminal(message)
        case .terminal(let cause, let message):
            throw Qwen36ProductionCanaryError.unexpectedTerminal(
                "\(cause): \(message)")
        }
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
        throw Qwen36ProductionCanaryError.capacityDidNotDrain(
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
}

private struct Qwen36ProductionCanaryFixture: @unchecked Sendable {
    let modelDirectory: URL
    let imageURL: URL
    let container: ModelContainer
    let targetSizing: SlotSizingSnapshot
    let tokenizer: TokenizerHandle

    func makeBundle(preparation: SpecDecPreparation) async throws -> ProviderEngineBundle {
        let prepared = try await EngineV2SlotFactory.prepareProductionModel(
            modelId: Qwen36ProductionCanary.modelID,
            isVLM: true,
            modelDirectory: modelDirectory,
            container: container,
            specDecPreparation: preparation)
        let sizing = targetSizing.replacingAuxiliaryWeightBytes(prepared.assistantBytes)
        let grant = Int(min(
            UnifiedMemoryCap.kvBudgetBytes(
                physicalBytes: ProcessInfo.processInfo.physicalMemory,
                residentWeightBytes: UInt64(max(0, sizing.weightsBytes)),
                configReserveBytes: 0),
            UInt64(Int.max)))
        do {
            return try await EngineV2SlotFactory.makeProductionBundle(
                modelId: Qwen36ProductionCanary.modelID,
                modelType: Qwen36ProductionCanary.modelType,
                isVLM: true,
                modelDirectory: modelDirectory,
                container: container,
                tokenizer: tokenizer,
                sizing: sizing,
                kvBytesCapacity: grant,
                maxConcurrentRequests: 2,
                kvBudget: nil,
                specDecPreparation: preparation,
                preparedModel: prepared,
                environment: [
                    "DARKBLOOM_PREFIX_CACHE": "0",
                    "DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS": "0",
                ])
        } catch {
            prepared.assistant?.release()
            MLX.Memory.clearCache()
            throw error
        }
    }

    func inlinePreparation() async -> SpecDecPreparation {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen36-production-canary-\(UUID().uuidString)")
        let funnel = SpecDecArtifactFunnel(
            resolver: SpecDecResolver(storeRoot: root),
            catalog: nil)
        let preparation = await funnel.prepare(.init(
            modelId: Qwen36ProductionCanary.modelID,
            modelType: Qwen36ProductionCanary.modelType,
            enabled: true,
            localPath: nil,
            modelDirectory: modelDirectory,
            allowDownload: false,
            environment: ["DARKBLOOM_CBV2_MTP": "1"]))
        await funnel.shutdown()
        try? FileManager.default.removeItem(at: root)
        return preparation
    }

    func scheduler(
        bundle: ProviderEngineBundle,
        vision: EngineV2VisionPlumbing? = nil
    ) -> MultiModelBatchSchedulerEngine {
        let entry = MultiModelBatchSchedulerEngine.ModelRegistryEntry(
            tokenizer: tokenizer,
            modelType: Qwen36ProductionCanary.modelType,
            container: container,
            isVLM: true,
            engineV2Bridge: bundle.bridge)
        return MultiModelBatchSchedulerEngine(
            registryProvider: { [entry] in [Qwen36ProductionCanary.modelID: entry] },
            defaultMaxTokens: 512,
            engineV2Vision: vision)
    }

    func textRequest() -> OpenAIChatCompletionRequest {
        OpenAIChatCompletionRequest(
            model: Qwen36ProductionCanary.modelID,
            messages: [.init(
                role: .user,
                content: .text(
                    "Compute 137 + 286. Return exactly "
                        + #"{"sum":423,"check":"ok"}"#
                        + " and nothing else."))],
            reasoning: .init(enabled: false),
            temperature: 0,
            topP: 1,
            topK: 0,
            minP: 0,
            maxTokens: 64)
    }

    func imageRequest() throws -> OpenAIChatCompletionRequest {
        let data = try Data(contentsOf: imageURL)
        let uri = "data:image/png;base64," + data.base64EncodedString()
        return OpenAIChatCompletionRequest(
            model: Qwen36ProductionCanary.modelID,
            messages: [.init(
                role: .user,
                content: .parts([
                    .text(
                        "Read the image and return exactly one compact JSON object with keys "
                            + "code, count, target, shapes, and colors. Preserve code and target "
                            + "exactly; use lowercase arrays in left-to-right order. Output JSON only."),
                    .imageURL(uri),
                ]))],
            reasoning: .init(enabled: false),
            temperature: 0,
            topP: 1,
            topK: 0,
            minP: 0,
            maxTokens: 128)
    }

    func toolRequest() -> OpenAIChatCompletionRequest {
        let schema: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "code": .object(["type": .string("string")]),
                "count": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("code"), .string("count")]),
            "additionalProperties": .bool(false),
        ])
        return OpenAIChatCompletionRequest(
            model: Qwen36ProductionCanary.modelID,
            messages: [.init(
                role: .user,
                content: .text(
                    "Call record_canary exactly once with code ORCHID-7319 and count 27. "
                        + "Do not write prose."))],
            tools: [.init(function: .init(
                name: "record_canary",
                description: "Record the deterministic production canary values.",
                parameters: schema))],
            toolChoice: .mode(.auto),
            toolCallParser: "qwen_xml",
            reasoning: .init(enabled: false),
            temperature: 0,
            topP: 1,
            topK: 0,
            minP: 0,
            maxTokens: 96)
    }

    func concurrentRequest(messages: [OpenAIChatMessage]) -> OpenAIChatCompletionRequest {
        OpenAIChatCompletionRequest(
            model: Qwen36ProductionCanary.modelID,
            messages: messages,
            reasoning: .init(enabled: false),
            temperature: 0,
            topP: 1,
            topK: 0,
            minP: 0,
            maxTokens: 16)
    }

    func parityRequest() -> OpenAIChatCompletionRequest {
        OpenAIChatCompletionRequest(
            model: Qwen36ProductionCanary.modelID,
            messages: [.init(
                role: .user,
                content: .text(
                    "Explain speculative decoding. Give a precise technical explanation covering "
                        + "draft proposals, target verification, rejection rollback, cache safety, "
                        + "and why greedy token identity must match target-only decoding."))],
            reasoning: .init(enabled: false),
            temperature: 0,
            topP: 1,
            topK: 0,
            minP: 0,
            maxTokens: Qwen36ProductionCanary.parityMaxTokens)
    }

    func tokenize(_ request: OpenAIChatCompletionRequest) throws -> [Int] {
        let prepared = try ToolChoicePromptPolicy.prepare(request)
        return try ProviderPromptContractPipeline.tokenize(
            prepared: prepared,
            request: request,
            tokenizer: tokenizer.inner,
            modelType: Qwen36ProductionCanary.modelType,
            reasoningEffort: nil)
    }

    func cancelAfterFirstDelta(
        bundle: ProviderEngineBundle
    ) async throws -> Qwen36ProductionCanaryCancellationResult {
        let openAIRequest = OpenAIChatCompletionRequest(
            model: Qwen36ProductionCanary.modelID,
            messages: [.init(
                role: .user,
                content: .text(
                    "Write a detailed 500-token explanation of deterministic distributed systems "
                        + "testing. Continue until the output limit and do not end early."))],
            reasoning: .init(enabled: false),
            temperature: 0,
            topP: 1,
            topK: 0,
            minP: 0,
            maxTokens: 512)
        let promptTokens = try tokenize(openAIRequest)
        let request = MultiModelBatchSchedulerEngine.translate(
            openAIRequest: openAIRequest,
            defaultMaxTokens: 512)
        let requestID = "qwen36-cancellation-canary"
        let stream = await bundle.bridge.submitTokenized(
            promptTokens: promptTokens,
            request: request,
            requestId: requestID,
            cacheEnabled: false)
        var result = Qwen36ProductionCanaryCancellationResult()
        for await event in stream {
            switch event {
            case .chunk:
                if !result.sawDelta {
                    result.sawDelta = true
                    await bundle.bridge.cancel(requestId: requestID)
                }
            case .info(let prompt, let completion, _, _):
                result.promptTokens = prompt
                result.completionTokens = completion
            case .error(let message):
                result.error = message
            case .terminal(let cause, let message, let prompt, let completion):
                result.promptTokens = prompt
                result.completionTokens = completion
                result.error = "\(cause.rawValue): \(message)"
            }
        }
        return result
    }
}

private struct Qwen36ProductionCanaryServerResult {
    var text = ""
    var toolCalls: [ToolCall] = []
    var info: ServerGenerationInfo?
}

private struct Qwen36ProductionCanaryCancellationResult {
    var sawDelta = false
    var promptTokens = 0
    var completionTokens = 0
    var error: String?
}

private final class Qwen36ProductionCanaryVisionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var state = (prepared: 0, spans: 0, refusals: 0)

    var preparedCount: Int { lock.withLock { state.prepared } }
    var lastSpanCount: Int { lock.withLock { state.spans } }
    var refusalCount: Int { lock.withLock { state.refusals } }

    func recordPrepared(spanCount: Int) {
        lock.withLock {
            state.prepared += 1
            state.spans = spanCount
        }
    }

    func recordRefusal() {
        lock.withLock { state.refusals += 1 }
    }
}

private enum Qwen36ProductionCanaryError: Error, CustomStringConvertible {
    case missingArtifact(String)
    case missingImage(String)
    case missingMetallib
    case notVLM(String)
    case engineUnavailable
    case emptyGeneration
    case missingTerminal
    case unexpectedTerminal(String)
    case capacityDidNotDrain(active: Int, waiting: Int, tokens: Int)
    case stage(String, String)

    var description: String {
        switch self {
        case .missingArtifact(let path):
            "Qwen3.6 artifact is missing at \(path)"
        case .missingImage(let path):
            "Qwen3.6 proof image is missing at \(path)"
        case .missingMetallib:
            "mlx.metallib is unavailable; run scripts/fetch-metallib.sh before the live canary"
        case .notVLM(let path):
            "Qwen3.6 artifact at \(path) does not declare vision_config"
        case .engineUnavailable:
            "production bundle released its EngineV2 before the canary submission"
        case .emptyGeneration:
            "production EngineV2 emitted no token IDs"
        case .missingTerminal:
            "production EngineV2 stream ended without a terminal event"
        case .unexpectedTerminal(let reason):
            "production EngineV2 ended unsuccessfully: \(reason)"
        case .capacityDidNotDrain(let active, let waiting, let tokens):
            "production EngineV2 capacity did not drain (active=\(active), waiting=\(waiting), "
                + "tokens=\(tokens))"
        case .stage(let stage, let detail):
            "Qwen3.6 production canary failed during \(stage): \(detail)"
        }
    }
}
