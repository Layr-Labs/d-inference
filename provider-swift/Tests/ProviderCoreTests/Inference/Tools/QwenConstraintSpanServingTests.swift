import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
import MLXNN
import Testing
@testable import ProviderCore

/// Qwen's verified vocabulary shape with distinct pieces for a literal stream.
/// The real provider still compiles its ordinary strict-tool constraint.
private struct SpanStreamTokenizer: MLXLMCommon.Tokenizer {
    static let promptID = 900
    static let firstPiece = 1000
    let pieces: [String]
    var thinking = true
    private let bytes = QwenByteTestTokenizer()

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        bytes.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.map { id in
            if id == Self.promptID { return QwenByteTestTokenizer.prompt(thinking: thinking) }
            if pieces.indices.contains(id - Self.firstPiece) { return pieces[id - Self.firstPiece] }
            return bytes.decode(tokenIds: [id], skipSpecialTokens: skipSpecialTokens)
        }.joined()
    }

    func convertTokenToId(_ token: String) -> Int? { bytes.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? {
        let piece: String
        if id == Self.promptID {
            piece = QwenByteTestTokenizer.prompt(thinking: thinking)
        } else if pieces.indices.contains(id - Self.firstPiece) {
            piece = pieces[id - Self.firstPiece]
        } else {
            return bytes.convertIdToToken(id)
        }
        return piece.utf8.map { bytes.convertIdToToken(Int($0))! }.joined()
    }
    var bosToken: String? { nil }
    var eosToken: String? { bytes.eosToken }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        #expect((additionalContext?["enable_thinking"] as? Bool ?? true) == thinking)
        return [Self.promptID]
    }
}

private final class SpanStreamCursor: CBv2MTPPreparedCapture {
    let offsets: [Int]
    var step = 0
    init(_ offsets: [Int]) { self.offsets = offsets }
}

/// The target is native; this transparent proposer makes draft boundaries
/// observable without claiming to qualify Qwen's persistent assistant history.
private final class SpanStreamDrafter: CBv2MTPDrafter {
    let mtpTargetIdentity: ObjectIdentifier?
    private let tokens: [Int]
    private let lock = NSLock()
    private var offsets: [Int] = []
    var starts: [Int] { lock.withLock { offsets } }

    init(target: Gemma4TextModel, tokens: [Int]) {
        mtpTargetIdentity = ObjectIdentifier(target)
        self.tokens = tokens
    }

    func prepare(rows: [CBv2MTPRowCapture]) -> CBv2MTPPreparedCapture {
        // One prompt token: anchor is the next output index after the seed.
        let starts = rows.map(\.anchor)
        lock.withLock { offsets += starts }
        return SpanStreamCursor(starts)
    }

    func draftStep(tokens: MLXArray, hidden: MLXArray, prepared: CBv2MTPPreparedCapture)
        -> (tokens: MLXArray, hidden: MLXArray) {
        let cursor = prepared as! SpanStreamCursor
        let next = cursor.offsets.map { index in
            Int32(self.tokens[min(index + cursor.step, self.tokens.count - 1)])
        }
        cursor.step += 1
        return (MLXArray(next), hidden)
    }
}

private struct SpanStreamOutcome {
    var content = ""
    var reasoning = ""
    var deltas: [ServerToolCallDelta] = []
    var info: ServerGenerationInfo?
    var terminals = 0
    private var parser = StreamingReasoningParser(format: .qwen3)

    mutating func record(_ event: MLXServerGenerationEvent) {
        switch event {
        case .content(let text): parser.parse(text).forEach { apply($0) }
        case .parsed(let value): apply(value)
        case .toolCallDelta(let delta): deltas.append(delta)
        case .info(let value): info = value; terminals += 1
        case .toolCall, .logprobs: break
        }
    }
    mutating func finish() { parser.finish().forEach { apply($0) } }
    private mutating func apply(_ value: ParsedReasoning) {
        content += value.content
        reasoning += value.reasoningContent ?? ""
    }
}

@Suite("Qwen constraint spans through native serving", .serialized)
struct QwenConstraintSpanServingTests {
    private static let pieces = [
        "Let", " me", " check", " the", " time", ".", "</think>",
        "One", " moment", ",", " please", ".", " ",
        "<tool_call>\n", "<function=get_time>\n", "<parameter=city>\n",
        "Ro", "me", "\n</parameter>\n", "</function>\n", "</tool_call>",
        "All", " done", ",", " thank", " you", ".",
    ]
    private static let tools = #"""
    [{"type":"function","function":{"name":"get_time","strict":true,
      "parameters":{"type":"object","properties":{"city":{"type":"string"}},
                    "required":["city"],"additionalProperties":false}}}]
    """#

    /// A small real Gemma target carries a fixed token code through native
    /// layers and KV updates. This qualifies provider/engine wiring, not a
    /// full Qwen model or the production Qwen assistant's history ownership.
    private func target(pieces: [String] = Self.pieces) throws -> Gemma4TextModel {
        let configuration = #"""
        {"model_type":"gemma4_text","hidden_size":64,"num_hidden_layers":6,
         "intermediate_size":128,"num_attention_heads":2,"head_dim":32,
         "global_head_dim":32,"num_key_value_heads":1,"num_kv_shared_layers":2,
         "layer_types":["sliding_attention","full_attention","full_attention",
                        "sliding_attention","sliding_attention","full_attention"],
         "sliding_window":16,"final_logit_softcapping":30.0,
         "tie_word_embeddings":false,"vocab_size":248320,"vocab_size_per_layer_input":248320,
         "rms_norm_eps":1e-6,"hidden_size_per_layer_input":0,"use_double_wide_mlp":false}
        """#
        let model = Gemma4TextModel(try JSONDecoder().decode(
            Gemma4TextConfiguration.self, from: Data(configuration.utf8)))
        let path = [SpanStreamTokenizer.promptID]
            + Array(SpanStreamTokenizer.firstPiece ..< SpanStreamTokenizer.firstPiece + pieces.count)
            + [StrictToolFixture.imEnd]
        let width = 64
        var embedding = [Float](repeating: 0, count: 248320 * width)
        var head = embedding
        for (index, token) in path.enumerated() {
            for column in 0..<width {
                let value: Float = index & (1 << (column % 6)) == 0 ? -0.25 : 0.25
                embedding[token * width + column] = value
                if index + 1 < path.count { head[path[index + 1] * width + column] = value }
            }
        }
        var replacements: [String: MLXArray] = [
            "model.embed_tokens.weight": MLXArray(embedding, [248320, width]),
            "lm_head.weight": MLXArray(head, [248320, width]),
        ]
        for (name, value) in model.parameters().flattened() {
            if name.hasSuffix(".self_attn.o_proj.weight") || name.hasSuffix(".mlp.down_proj.weight") {
                replacements[name] = MLXArray.zeros(value.shape, dtype: value.dtype)
            } else if name.hasSuffix(".layer_scalar") || name == "model.norm.weight" {
                replacements[name] = MLXArray.ones(value.shape, dtype: value.dtype)
            }
        }
        model.update(parameters: ModuleParameters.unflattened(replacements))
        eval(model)
        return model
    }

    private func engine(_ target: Gemma4TextModel, enabled: Bool,
                        pieces: [String] = Self.pieces, thinking: Bool = true)
        -> (EngineV2, SpanStreamDrafter, SpanStreamTokenizer) {
        let tokenizer = SpanStreamTokenizer(pieces: pieces, thinking: thinking)
        let tokens = Array(SpanStreamTokenizer.firstPiece ..< SpanStreamTokenizer.firstPiece + pieces.count)
            + [StrictToolFixture.imEnd]
        let drafter = SpanStreamDrafter(target: target, tokens: tokens)
        let kinds = target.cbv2LayerKinds
        let engine = EngineV2(model: CBv2SteppableLanguageModelAdapter(target), layerKinds: kinds,
            backend: CBv2ContiguousKVBackend(config: .init(bytesCapacity: 1 << 26)),
            cacheProvider: CBv2LayerCacheBank(layerKinds: kinds),
            detokenizerFactory: CBv2TextDetokenizerFactory(tokenizer: tokenizer),
            mtpDrafter: drafter,
            mtpConfig: .init(enabled: true, maxDraftTokens: 3, fixedDraftTokens: 3,
                verificationMode: .serialTarget, freeSpanSpeculation: enabled))
        return (engine, drafter, tokenizer)
    }

    @Test(.timeLimit(.minutes(3)))
    func strictAutoStreamDraftsAroundTheProtectedCall() async throws {
        let target = try target()
        // Prove this fixture actually supports MTP before the constrained red.
        let (unconstrained, _, _) = engine(target, enabled: true)
        var raw = ""
        for await event in try unconstrained.submit(.init(id: .init(1),
            promptTokens: [SpanStreamTokenizer.promptID], sampling: .init(temperature: 0),
            maxTokens: Self.pieces.count + 2, stopTokens: StrictToolFixture.stops)) {
            if case .delta(let text, _, _) = event { raw += text }
        }
        let control = try #require(unconstrained.mtpMetricsSnapshot())
        await unconstrained.shutdown()
        #expect(raw == Self.pieces.joined())
        #expect(control.acceptedTokens > 0)

        var baseline: SpanStreamOutcome?
        for enabled in [false, true] {
            let (native, drafter, tokenizer) = engine(target, enabled: enabled)
            let handle = TokenizerHandle(tokenizer)
            let id = StrictToolFixture.model
            let bridge = EngineV2Bridge(engine: native, modelId: id, tokenizer: handle,
                eosTokenIds: StrictToolFixture.stops, defaultMaxTokens: 64, maxConcurrentRequests: 1)
            let scheduler = MultiModelBatchSchedulerEngine(registryProvider: {
                [id: .init(tokenizer: handle, modelType: "qwen3_5", engineV2Bridge: bridge)]
            })
            let body = #"{"model":"\#(id)","messages":[{"role":"user","content":"time"}],"#
                + #""temperature":0,"reasoning":{"enabled":true},"reasoning_parser":"qwen3","#
                + #""max_tokens":64,"tools":\#(Self.tools)}"#
            var request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data(body.utf8))
            request.stream = true
            request.streamToolCallDeltas = true
            var outcome = SpanStreamOutcome()
            for try await event in try await scheduler.streamChatCompletion(request: request) {
                outcome.record(event)
            }
            outcome.finish()
            let metrics = try #require(native.mtpMetricsSnapshot())
            await bridge.shutdown()
            #expect(outcome.reasoning == "Let me check the time.")
            #expect(outcome.content == "One moment, please. All done, thank you.")
            let calls = outcome.deltas.compactMap(\.completed)
            #expect(calls.count == 1)
            #expect(calls.first?.function.name == "get_time")
            #expect(calls.first?.function.arguments == ["city": .string("Rome")])
            #expect(outcome.deltas.count > 2 && outcome.deltas.first?.name == "get_time")
            #expect(outcome.terminals == 1)
            if enabled {
                #expect(metrics.acceptedTokens > 0)
                #expect(drafter.starts.contains { $0 < 6 })
                #expect(drafter.starts.contains { $0 >= 21 })
                #expect(!drafter.starts.contains { (14..<21).contains($0) })
                #expect(outcome.info?.completionTokens == baseline?.info?.completionTokens)
                #expect(outcome.info?.stopReason == baseline?.info?.stopReason)
            } else {
                #expect(metrics.rounds == 0 && drafter.starts.isEmpty)
                baseline = outcome
            }
        }
    }

    @Test(.timeLimit(.minutes(3)), arguments: [false, true])
    func multipleCallsReturnToFreeTextWithThinkingOnOrOff(thinking: Bool) async throws {
        var pieces = thinking ? ["Let", " me", " check", " both", " clocks", ".", "</think>"] : []
        let before = pieces.count
        pieces += ["First", " city", " is", " next", ".", " "]
        let firstCall = pieces.count
        pieces += ["<tool", "_call>\n", "<function=get_time>\n", "<parameter=city>\n",
                   "Ro", "me", "\n</parameter>\n</function>\n</tool_call>"]
        let between = pieces.count
        pieces += ["One", " more", " city", " to", " check", ".", " "]
        let secondCall = pieces.count
        pieces += ["<tool_call>\n<function=get_time>\n<parameter=city>\n",
                   "Pa", "ris", "\n</parameter>\n", "</function>\n", "</tool_call>"]
        let after = pieces.count
        pieces += ["All", " done", ",", " thank", " you", "."]
        let target = try target(pieces: pieces)
        var baseline: SpanStreamOutcome?
        for enabled in [false, true] {
            let (native, drafter, tokenizer) = engine(target, enabled: enabled, pieces: pieces, thinking: thinking)
            let outcome = try await stream(native, tokenizer: tokenizer, thinking: thinking,
                extra: #""tools":\#(Self.tools)"#)
            let metrics = try #require(native.mtpMetricsSnapshot())
            #expect(outcome.reasoning == (thinking ? "Let me check both clocks." : ""))
            #expect(outcome.content == "First city is next. One more city to check. All done, thank you.")
            let calls = outcome.deltas.compactMap(\.completed)
            #expect(calls.map(\.function.name) == ["get_time", "get_time"])
            #expect(calls.map(\.function.arguments) == [["city": .string("Rome")], ["city": .string("Paris")]])
            #expect(outcome.deltas.count > 4 && outcome.terminals == 1)
            if enabled {
                #expect(metrics.acceptedTokens > 0)
                #expect(drafter.starts.contains { (before..<firstCall).contains($0) })
                #expect(drafter.starts.contains { (between..<secondCall).contains($0) })
                #expect(drafter.starts.contains { $0 >= after })
                #expect(!drafter.starts.contains {
                    ((firstCall + 1)..<between).contains($0) || ((secondCall + 1)..<after).contains($0)
                })
                #expect(outcome.info?.completionTokens == baseline?.info?.completionTokens)
                #expect(outcome.info?.stopReason == baseline?.info?.stopReason)
            } else {
                #expect(metrics.rounds == 0 && drafter.starts.isEmpty)
                baseline = outcome
            }
        }
    }

    /// Next vertical slice: the same public serving path must draft while
    /// thinking, then remain protected through the JSON value and trailing space.
    @Test(.timeLimit(.minutes(3)), arguments: [false, true])
    func jsonAnswerDraftsOnlyBeforeTheValue(thinking: Bool) async throws {
        var pieces = thinking ? ["Let", " me", " check", " the", " value", ".", "</think>"] : []
        let answerStart = pieces.count
        pieces += ["{", "\"city\"", ":", "\"", "Ro", "me", "\"", "}", " ", "\n", " "]
        let target = try target(pieces: pieces)
        var baseline: SpanStreamOutcome?
        for enabled in [false, true] {
            let (native, drafter, tokenizer) = engine(target, enabled: enabled, pieces: pieces, thinking: thinking)
            let outcome = try await stream(native, tokenizer: tokenizer, thinking: thinking,
                extra: #""response_format":{"type":"json_object"}"#)
            let metrics = try #require(native.mtpMetricsSnapshot())
            #expect(outcome.reasoning == (thinking ? "Let me check the value." : ""))
            #expect(outcome.content == "{\"city\":\"Rome\"} \n ")
            #expect(outcome.deltas.isEmpty && outcome.terminals == 1)
            #expect(!drafter.starts.contains { $0 >= answerStart })
            if enabled && thinking {
                #expect(metrics.acceptedTokens > 0)
                #expect(!drafter.starts.isEmpty)
            } else {
                #expect(metrics.rounds == 0 && drafter.starts.isEmpty)
            }
            if let baseline {
                #expect(outcome.info?.completionTokens == baseline.info?.completionTokens)
                #expect(outcome.info?.stopReason == baseline.info?.stopReason)
            } else { baseline = outcome }
        }
    }

    @Test func strictPreviewDoesNotInternDiscardedBoundaries() throws {
        let pieces = ["ordinary", "<", "<not-a-call",
            "<tool_call>\n<function=get_time>\n<parameter=city>\nRome\n</parameter>\n</function>\n</tool_call>",
            "<tool_call>\n<function=get_time>\n<parameter=city>\n", "Rome"]
        let (request, prepared) = try StrictToolFixture.prepared(StrictToolFixture.body(tools: Self.tools))
        let tokenizer = TokenizerHandle(SpanStreamTokenizer(pieces: pieces, thinking: false))
        let constraint = try #require(QwenStrictToolGrammar.constraint(
            prepared: prepared, request: request, parser: .qwen35, tokenizer: tokenizer,
            modelType: "qwen3_5", defaultMaxTokens: 64, stopTokenIDs: StrictToolFixture.stops,
            promptTokens: [SpanStreamTokenizer.promptID], runsTokenConstraints: true))
        let state = constraint.initialState
        let count = constraint.cachedStateCount
        #expect(constraint.isFreeSpan(state: state))
        for _ in 0..<10 {
            #expect(constraint.isFreeSpanContinuation(state: state, tokenID: 1000))
            for token in [1001, 1002, 1003, 1004, StrictToolFixture.imEnd, 248300, -1] {
                #expect(!constraint.isFreeSpanContinuation(state: state, tokenID: token))
            }
            #expect(!constraint.isFreeSpan(state: QwenStrictToolConstraint.releasedState))
            #expect(!constraint.isFreeSpan(state: -1))
        }
        #expect(constraint.cachedStateCount == count)
        #expect(constraint.nextState(state: state, tokenID: 1000) == state)
        // This token ends in the original state but transiently touched '<'.
        #expect(constraint.nextState(state: state, tokenID: 1002) == state)
        let partial = try #require(constraint.nextState(state: state, tokenID: 1001))
        let argument = try #require(constraint.nextState(state: state, tokenID: 1004))
        #expect(!constraint.isFreeSpan(state: partial))
        #expect(!constraint.isFreeSpan(state: argument))
        #expect(!constraint.isFreeSpanContinuation(state: argument, tokenID: 1005))
        let complete = try #require(constraint.nextState(state: state, tokenID: 1003))
        #expect(constraint.isFreeSpan(state: complete))
        #expect(constraint.allowedTokenIDs(state: complete, remainingTokens: 1)
            == constraint.allowedTokenIDs(state: complete, remainingTokens: 100))
    }

    @Test func installedProviderReceivesTheExplicitSpanSwitch() throws {
        for value: String? in [nil, "0", "1", "false", " true "] {
            let key = "DARKBLOOM_CONSTRAINT_SPANS"
            var environment = ["UNRELATED_SECRET": "excluded"]
            environment[key] = value
            let plist = LaunchAgent.makeServicePlist(label: LaunchAgent.label,
                programArguments: ["/test/darkbloom", "start", "--foreground"],
                logPath: "/test/provider.log", environment: environment)
            let encoded = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            let decoded = try #require(try PropertyListSerialization.propertyList(from: encoded, format: nil)
                as? [String: Any])
            let forwarded = decoded["EnvironmentVariables"] as? [String: String]
            #expect(forwarded?[key] == value)
            #expect(forwarded?["UNRELATED_SECRET"] == nil)
        }
    }

    private func stream(_ native: EngineV2, tokenizer: SpanStreamTokenizer,
                        thinking: Bool, extra: String) async throws -> SpanStreamOutcome {
        let handle = TokenizerHandle(tokenizer)
        let id = StrictToolFixture.model
        let bridge = EngineV2Bridge(engine: native, modelId: id, tokenizer: handle,
            eosTokenIds: StrictToolFixture.stops, defaultMaxTokens: 64, maxConcurrentRequests: 1)
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: {
            [id: .init(tokenizer: handle, modelType: "qwen3_5", engineV2Bridge: bridge)]
        })
        let body = #"{"model":"\#(id)","messages":[{"role":"user","content":"check"}],"#
            + #""temperature":0,"reasoning":{"enabled":\#(thinking)},"reasoning_parser":"qwen3","#
            + #""max_tokens":64,\#(extra)}"#
        var request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data(body.utf8))
        request.stream = true
        request.streamToolCallDeltas = true
        var outcome = SpanStreamOutcome()
        do {
            for try await event in try await scheduler.streamChatCompletion(request: request) { outcome.record(event) }
            outcome.finish()
            await bridge.shutdown()
            return outcome
        } catch {
            await bridge.shutdown()
            throw error
        }
    }
}
