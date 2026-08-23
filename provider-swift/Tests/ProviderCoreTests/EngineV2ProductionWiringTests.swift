// Copyright © 2026 Eigen Labs.
//
// Production request-routing seams for EngineV2 slots.
//
// Construction, re-slicing, failure unwind, heartbeat/capacity, KV backend,
// MTP, and state-file contracts live in their focused production-wiring suites.

import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import MLXNN
import Testing

@testable import ProviderCore




// MARK: - Request routing (inference handler + local endpoint shapes)

@Suite("EngineV2 production wiring: request routing")
struct EngineV2RequestRoutingTests {

    @Test("coordinator registryProvider path routes through the bridge")
    func coordinatorPathRoutesThroughBridge() async throws {
        let engine = ProductionWiringScriptedEngine(script: .stream([
            .delta(text: "Hello", tokens: [10], logprobs: nil),
            .delta(text: " world", tokens: [11], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 2)),
        ]))
        let bridge = productionMakeBridge(engine: engine)
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: productionMakeConstraintVerifiedWiringTokenizer(),
                        modelType: "gemma4",
                        engineV2Bridge: bridge)
                ]
            })

        let stream = try await providerEngine.streamChatCompletion(request: productionMakeOpenAIRequest())
        let events = try await productionRecordServerStream(stream)
        #expect(events.dropLast() == [.content("Hello"), .content(" world")])
        #expect(events.last == .info(prompt: 5, completion: 2))
        #expect(engine.submitted.count == 1)
        #expect(engine.submitted[0].promptTokens == [1, 2, 3, 4, 5])
    }

    /// Builds a provider engine whose stub tokenizer "renders" the given
    /// prompt tail, backed by a scripted close-only (Qwen3.6-style)
    /// thinking stream.
    private func makeThinkProbeEngine(
        decodedTail: String
    ) -> (ProductionWiringScriptedEngine, MultiModelBatchSchedulerEngine) {
        let engine = ProductionWiringScriptedEngine(script: .stream([
            .delta(text: "step one ", tokens: [10], logprobs: nil),
            .delta(text: "step two</think>Answer", tokens: [11], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 2)),
        ]))
        let bridge = productionMakeBridge(engine: engine, modelId: "qwen3.6-test")
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "qwen3.6-test": .init(
                        tokenizer: TokenizerHandle(
                            ProductionWiringStubTokenizer(decodeOverride: decodedTail)),
                        modelType: "qwen3_next",
                        engineV2Bridge: bridge)
                ]
            })
        return (engine, providerEngine)
    }

    @Test("a pre-opened think prompt injects a synthetic <think> ahead of close-only output")
    func preOpenedThinkPromptInjectsSyntheticOpen() async throws {
        let (engine, providerEngine) = makeThinkProbeEngine(
            decodedTail: "<|im_start|>assistant\n<think>\n")
        var request = productionMakeOpenAIRequest(model: "qwen3.6-test")
        request.stream = true
        request.reasoningParser = .qwen3

        let stream = try await providerEngine.streamChatCompletion(request: request)
        let events = try await productionRecordServerStream(stream)
        // The marker precedes the model's output; the downstream streaming
        // think parser consumes it as a state transition and then streams
        // each reasoning delta the moment it arrives (the TTFT fix).
        #expect(events == [
            .content("<think>"),
            .content("step one "),
            .content("step two</think>Answer"),
            .info(prompt: 5, completion: 2),
        ])
        // The marker is synthetic — it must never reach the engine/prompt.
        #expect(engine.submitted.count == 1)
    }

    @Test("no injection without a pre-opened think tail")
    func plainPromptTailDoesNotInject() async throws {
        let (_, providerEngine) = makeThinkProbeEngine(
            decodedTail: "<|im_start|>assistant\n")
        var request = productionMakeOpenAIRequest(model: "qwen3.6-test")
        request.stream = true
        request.reasoningParser = .qwen3

        let stream = try await providerEngine.streamChatCompletion(request: request)
        let events = try await productionRecordServerStream(stream)
        #expect(events.first == .content("step one "))
    }

    @Test("no injection for a non-think reasoning parser even with a pre-opened tail")
    func nonThinkParserDoesNotInject() async throws {
        let (_, providerEngine) = makeThinkProbeEngine(
            decodedTail: "<|im_start|>assistant\n<think>\n")
        var request = productionMakeOpenAIRequest(model: "qwen3.6-test")
        request.stream = true
        request.reasoningParser = .gemma4

        let stream = try await providerEngine.streamChatCompletion(request: request)
        let events = try await productionRecordServerStream(stream)
        #expect(events.first == .content("step one "))
    }

    @Test("required tool choice installs a CBv2 grammar before submission")
    func requiredToolChoiceInstallsGrammar() async throws {
        let engine = ProductionWiringScriptedEngine(script: .stream([
            .delta(text: "plain answer", tokens: [10], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 2)),
        ]))
        let bridge = productionMakeBridge(engine: engine)
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: productionMakeConstraintVerifiedWiringTokenizer(),
                        modelType: "gemma4",
                        engineV2Bridge: bridge)
                ]
            })
        let request = OpenAIChatCompletionRequest(
            model: "gemma-4-26b-qat-4bit",
            messages: [.init(role: .user, content: .text("hello"))],
            tools: [.init(function: .init(name: "calculate"))],
            toolChoice: .mode(.required))

        var emitted: [MLXServerGenerationEvent] = []
        do {
            let stream = try await providerEngine.streamChatCompletion(request: request)
            for try await event in stream {
                emitted.append(event)
            }
            Issue.record("scripted engine bypass should still fail validation")
        } catch let error as MultiModelBatchSchedulerEngineError {
            #expect(
                error == .toolChoiceViolation(
                    "required tool_choice produced visible text before a tool call"))
        }
        #expect(emitted.isEmpty)
        #expect(engine.submitted.count == 1)
        #expect(engine.submitted[0].tokenConstraint?.mode == .required)
    }

    @Test("required tool choice rejects an unpinned template contract before submit")
    func requiredToolChoiceRejectsUnpinnedTemplate() async throws {
        let engine = ProductionWiringScriptedEngine(script: .stream([]))
        let bridge = productionMakeBridge(engine: engine)
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
                        modelType: "gemma4",
                        engineV2Bridge: bridge)
                ]
            })
        let request = OpenAIChatCompletionRequest(
            model: "gemma-4-26b-qat-4bit",
            messages: [.init(role: .user, content: .text("hello"))],
            tools: [.init(function: .init(name: "calculate"))],
            toolChoice: .mode(.required))

        do {
            _ = try await providerEngine.streamChatCompletion(request: request)
            Issue.record("expected pinned prompt-contract rejection")
        } catch let error as MultiModelBatchSchedulerEngineError {
            #expect(
                error == .invalidToolPayload(
                    "inference-enforced tool_choice requires the pinned Gemma prompt contract"))
        }
        #expect(engine.submitted.isEmpty)
    }

    @Test("auto mode returns malformed tagged output as visible text")
    func autoToolParseFallbackIsVisible() async throws {
        let malformed =
            #"<|tool_call>call:bad{payload:[}<tool_call|>"#
        let engine = ProductionWiringScriptedEngine(script: .stream([
            .delta(text: malformed, tokens: [10], logprobs: nil),
            .finished(
                reason: .stop,
                usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = productionMakeBridge(engine: engine)
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: productionMakeConstraintVerifiedWiringTokenizer(),
                        modelType: "gemma4",
                        engineV2Bridge: bridge)
                ]
            })
        let request = OpenAIChatCompletionRequest(
            model: "gemma-4-26b-qat-4bit",
            messages: [.init(role: .user, content: .text("hello"))],
            tools: [.init(function: .init(name: "calculate"))],
            toolChoice: .mode(.auto))

        let stream = try await providerEngine.streamChatCompletion(request: request)
        var content = ""
        for try await event in stream {
            if case .content(let text) = event { content += text }
        }
        #expect(content == malformed)
        #expect(engine.submitted.first?.tokenConstraint == nil)
    }

    @Test("named tool choice rejects a parsed different function")
    func namedToolChoiceRejectsDifferentFunction() async throws {
        let engine = ProductionWiringScriptedEngine(script: .stream([
            .delta(
                text: "<tool_call><function=get_current_weather>"
                    + "<parameter=location>Boston</parameter></function></tool_call>",
                tokens: [10], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = productionMakeBridge(engine: engine)
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: productionMakeConstraintVerifiedWiringTokenizer(),
                        modelType: "gemma4",
                        engineV2Bridge: bridge)
                ]
            })
        let request = OpenAIChatCompletionRequest(
            model: "gemma-4-26b-qat-4bit",
            messages: [.init(role: .user, content: .text("weather"))],
            tools: [.init(function: .init(name: "calculate"))],
            toolChoice: .function(name: "calculate"))

        var emitted: [MLXServerGenerationEvent] = []
        do {
            let stream = try await providerEngine.streamChatCompletion(request: request)
            for try await event in stream {
                emitted.append(event)
            }
            Issue.record("expected named tool_choice mismatch")
        } catch let error as MultiModelBatchSchedulerEngineError {
            #expect(
                error == .toolChoiceViolation(
                    "named tool_choice produced visible text before a tool call"))
        }
        #expect(emitted.isEmpty)
    }

    @Test("constrained Gemma rejects a mismatched parser before submit")
    func constrainedToolChoiceRejectsParserOverride() async throws {
        let engine = ProductionWiringScriptedEngine(script: .stream([]))
        let bridge = productionMakeBridge(engine: engine)
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
                        modelType: "gemma4",
                        engineV2Bridge: bridge)
                ]
            })
        let request = OpenAIChatCompletionRequest(
            model: "gemma-4-26b-qat-4bit",
            messages: [.init(role: .user, content: .text("weather"))],
            tools: [.init(function: .init(name: "calculate"))],
            toolChoice: .mode(.required),
            toolCallParser: "json")
        do {
            _ = try await providerEngine.streamChatCompletion(request: request)
            Issue.record("expected parser mismatch rejection")
        } catch let error as MultiModelBatchSchedulerEngineError {
            #expect(error == .invalidToolPayload(
                "inference-enforced Gemma tool_choice requires the gemma tool parser"))
        }
        #expect(engine.submitted.isEmpty)
    }

    @Test("forced tool choice rejects multimodal requests before media work")
    func forcedToolChoiceRejectsMultimodalRequest() async throws {
        let engine = ProductionWiringScriptedEngine(script: .stream([]))
        let bridge = productionMakeBridge(engine: engine)
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
                        modelType: "gemma4",
                        container: productionMakeStubContainer(),
                        isVLM: true,
                        engineV2Bridge: bridge)
                ]
            })
        for choice: OpenAIToolChoice in [
            .mode(.required), .function(name: "calculate"),
        ] {
            let request = OpenAIChatCompletionRequest(
                model: "gemma-4-26b-qat-4bit",
                messages: [.init(
                    role: .user,
                    content: .parts([
                        .text("describe"),
                        .imageURL("data:image/png;base64,AA=="),
                    ]))],
                tools: [.init(function: .init(name: "calculate"))],
                toolChoice: choice)

            do {
                _ = try await providerEngine.streamChatCompletion(request: request)
                Issue.record("expected forced multimodal tool choice rejection")
            } catch let error as MultiModelBatchSchedulerEngineError {
                #expect(error == .invalidToolPayload(
                    "inference-enforced tool_choice is not supported for multimodal requests"))
            }
        }
        #expect(engine.submitted.isEmpty)
    }

    @Test("tool choice none is admitted on the multimodal path")
    func noneToolChoiceIsAdmittedForMultimodalRequest() async throws {
        let engine = ProductionWiringScriptedEngine(script: .stream([]))
        let bridge = productionMakeBridge(engine: engine)
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
                        modelType: "gemma4",
                        container: productionMakeStubContainer(),
                        isVLM: true,
                        engineV2Bridge: bridge)
                ]
            })
        let request = OpenAIChatCompletionRequest(
            model: "gemma-4-26b-qat-4bit",
            messages: [.init(
                role: .user,
                content: .parts([
                    .text("describe"),
                    .imageURL("data:image/png;base64,AA=="),
                ]))],
            tools: [.init(function: .init(name: "calculate"))],
            toolChoice: .mode(.none))

        // `none` hides the tools from the prompt and is enforced after
        // generation, so the media path constrains nothing and must admit it.
        // The request gets far enough to decode the (deliberately truncated)
        // PNG payload, which is exactly the step past the tool-choice guard.
        do {
            _ = try await providerEngine.streamChatCompletion(request: request)
            Issue.record("expected the stub media payload to fail decoding")
        } catch let error as MediaIngest.MediaError {
            #expect(error.description == "failed to decode image data into a CIImage")
        }
    }

    @Test("coordinator path threads cacheScope and logprobs plumbing into the bridge")
    func coordinatorPathThreadsSaltAndLogprobs() async throws {
        let engine = ProductionWiringScriptedEngine(script: .stream([
            .delta(
                text: "Hello", tokens: [10],
                logprobs: [CBv2TokenLogprob(token: 10, logprob: -0.25)]),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = productionMakeBridge(engine: engine)
        let channel = EngineV2LogprobsChannel()
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
                        modelType: "gemma4",
                        engineV2Bridge: bridge)
                ]
            },
            cacheScope: "tenant-hash",
            engineV2Logprobs: EngineV2LogprobsPlumbing(topLogprobs: 3, channel: channel)
        )
        let stream = try await providerEngine.streamChatCompletion(request: productionMakeOpenAIRequest())
        _ = try await productionRecordServerStream(stream)
        #expect(engine.submitted.count == 1)
        // TB-007: the tenant scope rode through as the per-request cache
        // salt (inert — production builds the v2 engine with the prefix
        // cache off).
        #expect(engine.submitted[0].cacheSalt == "tenant-hash")
        // The logprobs plumbing flipped the sampling translation on.
        #expect(engine.submitted[0].sampling.topLogprobs == 3)
        // Entries reached the per-request channel in OpenAI shape.
        let entries = channel.drain()
        #expect(entries.count == 1)
        #expect(entries[0].token == "t10")
        #expect(entries[0].logprob == -0.25)
    }

    @Test("coordinator path threads sealed-body logit_bias and seed into the engine")
    func coordinatorPathThreadsSamplingOverrides() async throws {
        let engine = ProductionWiringScriptedEngine(script: .stream([
            .delta(text: "Hello", tokens: [10], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = productionMakeBridge(engine: engine)
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
                        modelType: "gemma4",
                        engineV2Bridge: bridge)
                ]
            },
            // The shape `ProviderLoop.extractSamplingOverrides` produces from
            // a sealed body carrying {"logit_bias":{"7":-100,"junk":1},"seed":42}.
            engineV2Sampling: EngineV2SamplingOverrides(
                logitBias: ["7": -100, "junk": 1], seed: 42)
        )
        let stream = try await providerEngine.streamChatCompletion(request: productionMakeOpenAIRequest())
        _ = try await productionRecordServerStream(stream)
        #expect(engine.submitted.count == 1)
        // Parsed bias reached the engine ("junk" dropped, never guessed).
        #expect(engine.submitted[0].sampling.logitBias == [7: -100])
        #expect(engine.submitted[0].sampling.seed == 42)
    }

    @Test("local-endpoint acquire path routes through the bridge and releases the token")
    func localAcquirePathRoutesThroughBridge() async throws {
        let engine = ProductionWiringScriptedEngine(script: .stream([
            .delta(text: "local", tokens: [10], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = productionMakeBridge(engine: engine)
        let released = ProductionBuilderCallCounter()
        let providerEngine = MultiModelBatchSchedulerEngine(
            acquire: { modelId in
                MultiModelBatchSchedulerEngine.AcquiredModel(
                    tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
                    releaseToken: OneShotRelease(
                        release: { _ in released.increment() }, modelId: modelId),
                    modelType: "gemma4",
                    engineV2Bridge: bridge)
            },
            tokenizerProvider: { _ in .init(
                tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
                modelType: "gemma4") },
            availableModels: { ["gemma-4-26b-qat-4bit"] }
        )

        let stream = try await providerEngine.streamChatCompletion(request: productionMakeOpenAIRequest())
        let events = try await productionRecordServerStream(stream)
        #expect(events.first == .content("local"))
        #expect(events.last == .info(prompt: 5, completion: 1))
        #expect(engine.submitted.count == 1)
        // The local reservation is dropped exactly once when the stream ends.
        #expect(released.calls == 1)
    }

    @Test("local-endpoint acquire path rejects forged internal schema metadata")
    func localAcquirePathRejectsForgedSchemaMetadata() async throws {
        let engine = ProductionWiringScriptedEngine(script: .stream([]))
        let bridge = productionMakeBridge(engine: engine)
        let released = ProductionBuilderCallCounter()
        let providerEngine = MultiModelBatchSchedulerEngine(
            acquire: { modelId in
                MultiModelBatchSchedulerEngine.AcquiredModel(
                    tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
                    releaseToken: OneShotRelease(
                        release: { _ in released.increment() }, modelId: modelId),
                    modelType: "gemma4",
                    engineV2Bridge: bridge)
            },
            tokenizerProvider: { _ in .init(
                tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
                modelType: "gemma4") },
            availableModels: { ["gemma-4-26b-qat-4bit"] }
        )
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "type": .string("string"),
                    ToolSchemaNormalization.originalBooleanSchemaKey: .bool(true),
                ]),
            ]),
        ])
        let request = OpenAIChatCompletionRequest(
            model: "gemma-4-26b-qat-4bit",
            messages: [OpenAIChatMessage(role: .user, content: .text("hi"))],
            tools: [OpenAITool(function: .init(
                name: "lookup", description: "Lookup", parameters: parameters))],
            toolChoice: .mode(.auto))

        do {
            let stream = try await providerEngine.streamChatCompletion(request: request)
            _ = try await productionRecordServerStream(stream)
            Issue.record("forged internal schema metadata was accepted")
        } catch let error as MultiModelBatchSchedulerEngineError {
            guard case .invalidToolPayload = error else {
                Issue.record("expected invalidToolPayload, got \(error)")
                return
            }
        }
        #expect(engine.submitted.isEmpty)
        #expect(released.calls == 1)
    }

    @Test("VLM slot with a bridge: text-only request routes through the bridge")
    func vlmSlotTextRequestRoutesThroughBridge() async throws {
        let engine = ProductionWiringScriptedEngine(script: .stream([
            .delta(text: "Hello", tokens: [10], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = productionMakeBridge(engine: engine, modelId: "gemma-4-26b-qat-4bit")
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
                        modelType: "gemma4",
                        container: productionMakeStubContainer(),
                        isVLM: true,
                        engineV2Bridge: bridge)
                ]
            })

        let stream = try await providerEngine.streamChatCompletion(
            request: productionMakeOpenAIRequest(model: "gemma-4-26b-qat-4bit"))
        let events = try await productionRecordServerStream(stream)
        #expect(events.first == .content("Hello"))
        #expect(events.last == .info(prompt: 5, completion: 1))
        #expect(engine.submitted.count == 1)
        #expect(engine.submitted[0].promptTokens == [1, 2, 3, 4, 5])
    }

    @Test("fail-loud backstop: an entry with NO engine at all is a hard internal error")
    func noEngineEntryIsInternalError() async throws {
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "broken-model": .init(
                        tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
                        modelType: "gemma4")
                ]
            })

        do {
            let stream = try await providerEngine.streamChatCompletion(
                request: productionMakeOpenAIRequest(model: "broken-model"))
            _ = try await productionRecordServerStream(stream)
            Issue.record("expected the no-engine backstop to throw")
        } catch let error as MultiModelBatchSchedulerEngineError {
            guard case .generationFailed(let message) = error else {
                Issue.record("expected generationFailed, got \(error)")
                return
            }
            #expect(message.contains("no serving engine"))
            // 500 — a provider fault, never a silent degrade.
            #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 500)
        }
    }

    @Test("VLM slot with a bridge: image-bearing request never reaches the bridge")
    func vlmSlotMediaRequestBypassesBridge() async throws {
        // The media check sits ABOVE the bridge branch (ordering contract in
        // MultiModelBatchSchedulerEngine.streamChatCompletion): an
        // image-bearing request on a bridge-carrying VLM slot must take the
        // media path — here it fails inside that path (stub container /
        // throwing processor), which is exactly the proof: the scripted v2
        // engine must never see a TEXT-path submission.
        let engine = ProductionWiringScriptedEngine(script: .stream([
            .delta(text: "must-not-appear", tokens: [10], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = productionMakeBridge(engine: engine, modelId: "gemma-4-26b-qat-4bit")
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
                        modelType: "gemma4",
                        container: productionMakeStubContainer(),
                        isVLM: true,
                        engineV2Bridge: bridge)
                ]
            })

        // A real, round-trip-verified 1x1 PNG so hasMedia + media validation
        // both engage (same fixture as MediaIngestTests).
        let tinyPNG =
            "data:image/png;base64,"
            + "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAAAXNSR0IArs4c6QAAAERl"
            + "WElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAAB"
            + "AAAAAaADAAQAAAABAAAAAQAAAAD5Ip3+AAAADElEQVQIHWP4z8AAAAMBAQBb2/lEAAAA"
            + "AElFTkSuQmCC"
        let mediaRequest = OpenAIChatCompletionRequest(
            model: "gemma-4-26b-qat-4bit",
            messages: [
                OpenAIChatMessage(
                    role: .user,
                    content: .parts([
                        .text("what is this?"),
                        .imageURL(tinyPNG),
                    ]))
            ]
        )

        // The vision path errors on the stub fixtures (throwing processor) —
        // either shape proves the routing; what must NOT happen is a silent
        // success through the bridge's TEXT path.
        do {
            let stream = try await providerEngine.streamChatCompletion(request: mediaRequest)
            _ = try await productionRecordServerStream(stream)
            Issue.record("media request unexpectedly succeeded on stub fixtures")
        } catch {
            // expected: media path surfaced its failure
        }
        // The v2 vision seam MAY have attempted a multimodal submission
        // (production plumbing); what it must never do is serve the request
        // through the TEXT tokenization path. With the throwing stub
        // processor nothing was ever submitted at all.
        #expect(engine.submitted.isEmpty)
    }

    @Test("cancelling the consumer cancels the engine-minted v2 request id")
    func cancellationPropagatesToBridge() async throws {
        let engine = ProductionWiringScriptedEngine(script: .manual)
        let bridge = productionMakeBridge(engine: engine)
        let providerEngine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "gemma-4-26b-qat-4bit": .init(
                        tokenizer: TokenizerHandle(ProductionWiringStubTokenizer()),
                        modelType: "gemma4",
                        engineV2Bridge: bridge)
                ]
            })

        let stream = try await providerEngine.streamChatCompletion(request: productionMakeOpenAIRequest())
        let consumer = Task {
            for try await _ in stream {}
        }
        // Wait until the request reaches the engine, then cancel the consumer.
        for _ in 0..<200 where engine.submitted.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(engine.submitted.count == 1)
        consumer.cancel()
        _ = try? await consumer.value

        // Task cancellation propagates: outer stream → engine wrapper
        // (cancelUpstream → bridge.cancel) and/or the bridge stream's own
        // onTermination — either way the ENGINE-minted id gets cancelled.
        for _ in 0..<200 where engine.cancelled.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(engine.cancelled.first == engine.submitted.first?.id)
    }
}


