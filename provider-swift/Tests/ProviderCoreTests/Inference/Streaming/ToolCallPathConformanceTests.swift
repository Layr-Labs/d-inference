// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

#if DEBUG
/// The same model output, served to a client that streams and to one that
/// does not, must end the same way: the same finished calls, the same finish
/// reason, and refused or not alike. One row per served model type, each
/// through its owner's production wiring: the scheduler's prepared choice,
/// tool handler, channel set-up (`TextOutputRouting`) and forwarder, or
/// Nemotron 3.5 Super's request plan, output and relay; then the service's
/// own frames.
///
/// Only a family and tool choice whose two clients take different paths is a
/// comparison of the streamed path with the withheld one. Where both clients
/// take one path (`singlePath`) the cells compare that path with itself and
/// are kept out of the agreement test and its count.
///
/// Where the two paths disagree today the cell is listed in
/// `knownDivergences` with both outcomes. That list may only shrink: a cell
/// that starts to agree fails until its entry is removed, and a cell that
/// starts to disagree, or disagrees differently, fails until it is fixed.
@Suite("Tool-call paths: a streamed and a withheld call end the same way")
struct ToolCallPathConformanceTests {
    // MARK: - Families

    /// How a family writes one call.
    enum Dialect: Sendable {
        case gemma, harmony, taggedLines, taggedInline, argumentPairs, json

        func open(_ name: String) -> String {
            switch self {
            case .gemma: "<|tool_call>call:\(name){"
            case .harmony: "<|start|>assistant to=functions.\(name)<|channel|>commentary json<|message|>{"
            case .taggedLines: "<tool_call>\n<function=\(name)>\n"
            case .taggedInline: "<tool_call><function=\(name)>"
            case .argumentPairs: "<tool_call>\(name)"
            case .json: #"<tool_call>{"name": ""# + name + #"", "arguments": {"#
            }
        }

        /// One string argument, written up to and including `value`.
        func argumentHead(_ key: String, _ value: String) -> String {
            switch self {
            case .gemma: "\(key):<|\"|>\(value)"
            case .harmony, .json: "\"\(key)\":\"\(value)"
            case .taggedLines: "<parameter=\(key)>\n\(value)"
            case .taggedInline: "<parameter=\(key)>\(value)"
            case .argumentPairs: "<arg_key>\(key)</arg_key><arg_value>\(value)"
            }
        }

        var argumentTail: String {
            switch self {
            case .gemma: "<|\"|>"
            case .harmony, .json: "\""
            case .taggedLines: "\n</parameter>\n"
            case .taggedInline: "</parameter>"
            case .argumentPairs: "</arg_value>"
            }
        }

        var separator: String {
            switch self {
            case .gemma, .harmony, .json: ","
            case .taggedLines, .taggedInline, .argumentPairs: ""
            }
        }

        var close: String {
            switch self {
            case .gemma: "}<tool_call|>"
            case .harmony: "}<|call|>"
            case .taggedLines: "</function>\n</tool_call>"
            case .taggedInline: "</function></tool_call>"
            case .argumentPairs: "</tool_call>"
            case .json: "}}</tool_call>"
            }
        }

        func call(_ name: String, _ arguments: [(String, String)]) -> String {
            open(name) + arguments.map { argumentHead($0.0, $0.1) + argumentTail }.joined(separator: separator) + close
        }

        /// A closed frame that names no call.
        var unreadable: String {
            switch self {
            case .gemma: "<|tool_call>not a call<tool_call|>"
            case .harmony:
                "<|start|>assistant to=functions.get_weather<|channel|>commentary json<|message|>not json<|call|>"
            case .taggedLines, .taggedInline, .argumentPairs, .json: "<tool_call>not a call</tool_call>"
            }
        }
    }

    enum Owner: Sendable { case scheduler, superOwner }

    struct Family: Sendable, CustomTestStringConvertible {
        let name: String
        let type: ServedModelType
        let model: String
        let dialect: Dialect
        /// The end of the rendered prompt with thinking off, as the family's
        /// template leaves it: the output starts in its answer.
        var promptTail = ""
        var owner = Owner.scheduler
        var testDescription: String { name }
    }

    static let closedThought = "<|im_start|>assistant\n<think>\n\n</think>\n\n"

    static let families: [Family] = [
        .init(name: "Gemma 4", type: .gemma4, model: "gemma-4-26b-qat-4bit", dialect: .gemma),
        .init(name: "Gemma 4 text", type: .gemma4Text, model: "gemma-4-26b-text", dialect: .gemma),
        .init(name: "GPT-OSS", type: .gptOSS, model: "gpt-oss-20b", dialect: .harmony),
        .init(name: "Qwen 3.5 and 3.8 dense", type: .qwen35, model: "Qwen3.5-9B", dialect: .taggedLines,
              promptTail: closedThought),
        .init(name: "Qwen 3.5 and 3.6 MoE", type: .qwen35MoE, model: "qwen3.5-35b-a3b", dialect: .taggedLines,
              promptTail: closedThought),
        .init(name: "Qwen3-VL", type: .qwen3VLMoE, model: "qwen3-vl-30b-a3b", dialect: .json,
              promptTail: "<|im_start|>assistant\n"),
        .init(name: "Bonsai 2", type: .prismHadamardQwen35, model: "ternary-bonsai-2-27b", dialect: .taggedLines,
              promptTail: closedThought),
        .init(name: "MiMo V2.6", type: .mimoV2, model: "mimo-v2.6-flash-mopd", dialect: .taggedInline,
              promptTail: "<|im_start|>assistant\n"),
        .init(name: "Nemotron 3.5 Lightning", type: .nemotronH, model: "nvidia-nemotron-3.5-lightning",
              dialect: .taggedLines, promptTail: "<|im_start|>assistant\n<think></think>"),
        .init(name: "Nemotron 3.5 Super", type: .nemotronHOmni, model: NemotronSuperLocalBinding.modelID,
              dialect: .taggedLines, owner: .superOwner),
        .init(name: "GLM-5.3-Flash", type: .glm5Next, model: GLM5NextCoordinatorServing.catalogModelID,
              dialect: .argumentPairs, promptTail: "<|assistant|><think></think>"),
        .init(name: "Qwen 4", type: .qwen4Exp, model: "qwen4-exp", dialect: .taggedLines, promptTail: closedThought),
        .init(name: "Qwen 4 text", type: .qwen4ExpText, model: "qwen4-exp-text", dialect: .taggedLines,
              promptTail: closedThought),
        .init(name: "diffusion Gemma", type: .diffusionGemma, model: "diffusion-gemma", dialect: .gemma),
        .init(name: "Flint", type: .flint, model: "flint", dialect: .argumentPairs, promptTail: "<|assistant|>"),
    ]

    // MARK: - Requests and outputs

    enum Choice: String, CaseIterable, Sendable {
        case auto, required, named

        var json: String {
            switch self {
            case .auto: #""auto""#
            case .required: #""required""#
            case .named: #"{"type":"function","function":{"name":"get_weather"}}"#
            }
        }
    }

    /// What the model wrote, and how the engine ended it.
    enum Scenario: String, CaseIterable, Sendable {
        /// One complete call.
        case complete
        /// The token limit cut the answer inside the call's arguments (`length`).
        case cut
        /// The model ended its turn inside the call's arguments (`stop`).
        case endInsideFrame
        /// A closed frame that names no call.
        case malformed
        /// A closed frame that names its function, then repeats an argument.
        case repeatedArgument
        /// Text, then one complete call.
        case textBeforeCall
        /// One complete call to a function the request did not declare.
        case undeclaredFunction
        /// One complete call that keeps its frame but breaks its schema: the
        /// required argument is missing and another is not declared.
        case schemaBreak

        func output(_ dialect: Dialect) -> String {
            let head = dialect.open("get_weather") + dialect.argumentHead("city", "Par")
            switch self {
            case .complete: return dialect.call("get_weather", [("city", "Paris")])
            case .cut, .endInsideFrame: return head
            case .malformed: return dialect.unreadable
            case .repeatedArgument: return dialect.call("get_weather", [("city", "Paris"), ("city", "Rome")])
            case .textBeforeCall: return "Sure! " + dialect.call("get_weather", [("city", "Paris")])
            case .undeclaredFunction: return dialect.call("delete_files", [("path", "/")])
            case .schemaBreak: return dialect.call("get_weather", [("note", "x")])
            }
        }

        var finishReason: String { self == .cut ? "length" : "stop" }
    }

    static let tools = #"[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}},{"type":"function","function":{"name":"write_file","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}}]"#

    /// The client's own body. Super reads thinking from it; its output here
    /// starts in the answer, as every other family's does.
    static func body(_ family: Family, _ choice: Choice, clientStreams: Bool) -> Data {
        Data((#"{"model":""# + family.model + #"","messages":[{"role":"user","content":"Weather in Paris?"}],"#
            + #""max_tokens":600,"stream":"# + (clientStreams ? "true" : "false") + #","tools":"# + tools
            + #","tool_choice":"# + choice.json
            + (family.owner == .superOwner ? #","chat_template_kwargs":{"enable_thinking":false}"# : "") + "}").utf8)
    }

    // MARK: - One response

    struct Outcome: Equatable, CustomStringConvertible {
        /// Calls the response finished, as name and canonical arguments.
        var calls: [String] = []
        var finishReason: String?
        /// The answer text the client received.
        var text = ""
        /// Nil when served; otherwise the refusal as the coordinator classes
        /// it (the model's noncompliance, or the engine error's kind).
        var refusal: String?
        /// Which check refused it. Telemetry detail: the streamed path names
        /// the frame's own fault, so it is shown but not compared.
        var check: String?
        /// The request's tool-call tally, when its owner recorded one.
        var tally: ToolCallTally?
        /// Whether the owner exposed this response's calls while generated;
        /// nil when the request was refused before an owner took it. Not
        /// compared: it names the path, which the two clients differ by.
        var streamsCalls: Bool?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.calls == rhs.calls && lhs.finishReason == rhs.finishReason && lhs.text == rhs.text
                && lhs.refusal == rhs.refusal
        }

        var description: String {
            if let refusal { return "refused (" + refusal + (check.map { ": " + $0 } ?? "") + ")" }
            return (finishReason ?? "no finish") + ", " + (calls.isEmpty ? "no call" : calls.joined(separator: " "))
                + (text.isEmpty ? "" : showsFrame ? ", the frame as text" : ", text " + text.debugDescription)
        }

        /// The answer text holds a call frame's own markup.
        var showsFrame: Bool {
            ["<tool_call", "<|tool_call>", "<|start|>", "<function=", "<arg_key>"].contains { text.contains($0) }
        }
    }

    /// Every call an engine stream finished, read beside the service's
    /// frames, and the path its owner resolved.
    final class FinishedCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        private var path: Bool?

        /// The owner's own answer: its calls leave while generated.
        func note(streamsCalls: Bool) { lock.withLock { path = streamsCalls } }
        var streamsCalls: Bool? { lock.withLock { path } }

        func record(_ event: MLXServerGenerationEvent) {
            let call: ToolCall? = switch event {
            case .toolCall(let call): call
            case .toolCallDelta(let delta): delta.completed
            default: nil
            }
            guard let call, let data = try? JSONEncoder.sortedKeys.encode(call.function.arguments) else { return }
            lock.withLock { calls.append(call.function.name + String(decoding: data, as: UTF8.self)) }
        }

        var all: [String] { lock.withLock { calls } }
    }

    /// One owner's production event stream for `output`, recorded. Whether
    /// the client streams is read from `body`, as each owner reads it.
    struct WiredEngine: MLXServerEngine {
        let family: Family
        let body: Data
        let output: String
        let finishReason: String
        let finished: FinishedCalls
        let usage: EngineV2RequestUsageSignal

        func availableModels() async throws -> [MLXServerModel] { [] }
        func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse { .init(tokens: []) }
        func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse { .init(text: "") }
        func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse { .init(tokens: []) }

        var upstream: [GenerationEvent] {
            let characters = Array(output)
            return stride(from: 0, to: characters.count, by: 3).map {
                .chunk(String(characters[$0 ..< min($0 + 3, characters.count)]))
            } + [.info(promptTokens: 9, completionTokens: 30, tokensPerSecond: 0, finishReason: finishReason)]
        }

        func streamChatCompletion(
            request: OpenAIChatCompletionRequest
        ) async throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
            let events = switch family.owner {
            case .scheduler: try schedulerEvents(request)
            case .superOwner: try superOwnerEvents(request)
            }
            let finished = self.finished
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await event in events {
                            finished.record(event)
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        /// As `MultiModelBatchSchedulerEngine.prepareCompletion` wires a text request.
        private func schedulerEvents(
            _ request: OpenAIChatCompletionRequest
        ) throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
            let modelType = family.type.rawValue
            let controls = try JSONDecoder().decode(ChatTemplateControls.self, from: body)
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: modelType).serving(
                declaredTools: controls.declaredTools,
                clientStreams: controls.clientStreams ?? (request.stream == true),
                returnsStrictCallsAsGenerated: StrictToolCallPolicy.returnsAsGenerated)
            let handler = try ToolStreamPreparation.makeHandler(
                request: request, prepared: prepared, modelType: modelType)
            let promptTail = family.promptTail
            let promptReasoningPrefix = ReasoningPromptProbe.streamingPrefix(
                reasoningParser: request.reasoningParser, stream: request.stream, promptTokens: [0],
                modelType: modelType, decodeTail: { _ in promptTail })
            let withholdsGLMOutput = GLM5NextPromptPolicy.withholdsOutput(prepared, modelType: modelType)
            // These requests ask for no JSON answer, so none is constrained.
            let routing = TextOutputRouting.resolve(
                request: request, prepared: prepared, modelType: modelType, toolParser: handler?.format,
                jsonAnswerChannelPrefix: nil, withholdsGLMOutput: withholdsGLMOutput,
                glmWithholdsReasoning: GLM5NextPromptPolicy.withholdsReasoning(controls, modelType: modelType),
                reasoningPrefix: promptReasoningPrefix, promptReasoningPrefix: promptReasoningPrefix,
                promptThinkState: { ReasoningPromptProbe.streamingPrefix(forPromptTail: promptTail) })
            finished.note(streamsCalls: handler?.streamsCalls == true || routing.streamsGLMCalls)
            let events = upstream
            return try MultiModelBatchSchedulerEngine(registryProvider: { [:] })._testMakeEventStream(
                upstream: AsyncStream { continuation in
                    for event in events { continuation.yield(event) }
                    continuation.finish()
                },
                cancelUpstream: {}, prepared: prepared,
                releaseBox: OneShotRelease(release: { _ in }, modelId: request.model), toolHandler: handler,
                routing: routing, reasoningPrefix: promptReasoningPrefix, recordsWithheldOutput: withholdsGLMOutput,
                usageSignal: usage)
        }

        /// As `NemotronSuperLocalImageHTTP` wires a text request: the plan
        /// from the client's body, the output, and the relay that feeds it.
        private func superOwnerEvents(
            _ request: OpenAIChatCompletionRequest
        ) throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
            let plan = try NemotronSuperRequestPlan(body: body, formatted: request)
            let output = try NemotronSuperLocalOutput(plan: plan, streaming: request.stream == true)
            finished.note(streamsCalls: output.streamsToolCalls)
            let pair = AsyncThrowingStream<MLXServerGenerationEvent, Error>.makeStream(
                bufferingPolicy: .bufferingOldest(4096))
            let relay = SuperImageHTTPRelay(continuation: pair.continuation, output: output, usageSignal: usage)
            let events = upstream
            Task {
                for event in events { await relay.accept(event) }
                await relay.complete()
            }
            return pair.stream
        }
    }

    /// The request as the coordinator path hands it to the engine: always a
    /// stream with usage, with the family's reasoning parser
    /// (`ProviderLoop.handleInferenceRequest`). Super's owner splits its own
    /// reasoning, so it gets none.
    static func serve(_ family: Family, _ choice: Choice, _ scenario: Scenario, clientStreams: Bool) async -> Outcome {
        let body = body(family, choice, clientStreams: clientStreams)
        let finished = FinishedCalls()
        let usage = EngineV2RequestUsageSignal()
        var outcome = Outcome()
        do {
            var request = try ProviderLoop.decodeOpenAIRequest(body)
            request.stream = true
            request.streamOptions = .init(includeUsage: true)
            if family.owner == .scheduler {
                request.reasoningParser = ProviderLoop.inferReasoningParser(for: family.type.rawValue)
            }
            let engine = WiredEngine(family: family, body: body, output: scenario.output(family.dialect),
                finishReason: scenario.finishReason, finished: finished, usage: usage)
            for try await frame in try await MLXOpenAIService(engine: engine).streamChatCompletionFrames(
                request: request)
            {
                guard let chunk = ProviderLoop.parseStreamChunk(frame) else { continue }
                outcome.text += chunk.contentDelta ?? ""
                if let reason = chunk.finishReason { outcome.finishReason = reason }
            }
            outcome.calls = finished.all
        } catch {
            outcome = Self.refused(error)
        }
        outcome.tally = usage.toolCalls
        outcome.streamsCalls = finished.streamsCalls
        return outcome
    }

    /// A refusal as the coordinator would class it, and the check behind it.
    static func refused(_ error: Error) -> Outcome {
        if let check = classifyToolNoncomplianceCheck(error) {
            return Outcome(refusal: "tool_noncompliance", check: check.rawValue)
        }
        guard let engineError = error as? MultiModelBatchSchedulerEngineError else {
            return Outcome(refusal: "\(type(of: error))")
        }
        return Outcome(refusal: String(String(describing: engineError).prefix { $0 != "(" }))
    }

    // MARK: - The matrix

    static func cell(_ family: Family, _ choice: Choice, _ scenario: Scenario) -> String {
        "\(family.name) / \(choice.rawValue) / \(scenario.rawValue)"
    }

    /// Cells where the two paths disagree today: the streamed outcome, then
    /// the withheld one. Recorded, not endorsed: remove a cell when it agrees.
    static let knownDivergences: [String: String] = Dictionary(uniqueKeysWithValues: [
        // A frame that repeats an argument. Streamed, the first value already
        // left, the parse keeps the last, and the call is refused as diverged.
        // Withheld, the parse's value is returned.
        (#"refused (tool_noncompliance: diverged) | tool_calls, get_weather{"city":"Rome"}"#, [
            "Gemma 4 / required / repeatedArgument", "Gemma 4 / named / repeatedArgument",
            "Gemma 4 text / required / repeatedArgument", "Gemma 4 text / named / repeatedArgument",
            "Qwen 3.5 and 3.8 dense / required / repeatedArgument",
            "Qwen 3.5 and 3.8 dense / named / repeatedArgument",
            "Qwen 3.5 and 3.6 MoE / required / repeatedArgument", "Qwen 3.5 and 3.6 MoE / named / repeatedArgument",
            "Bonsai 2 / auto / repeatedArgument", "Bonsai 2 / required / repeatedArgument",
            "Bonsai 2 / named / repeatedArgument",
        ]),
        // An `auto` frame its parser refuses. Streamed, it is refused after
        // its name left. Withheld, the router does not count a Nemotron or
        // GLM `auto` parse failure as one (`hasNativeToolFailure`,
        // `GLM5ToolSuffix`), and the frame is returned as answer text.
        ("refused (tool_noncompliance: malformed) | stop, no call, the frame as text", [
            "Nemotron 3.5 Lightning / auto / repeatedArgument", "GLM-5.3-Flash / auto / repeatedArgument",
        ]),
        // An `auto` call the model stopped inside. Streamed, the open call
        // is refused. Withheld, the unfinished frame is returned as answer text.
        ("refused (tool_noncompliance: unterminated) | stop, no call, the frame as text", [
            "Bonsai 2 / auto / endInsideFrame", "Nemotron 3.5 Lightning / auto / endInsideFrame",
            "GLM-5.3-Flash / auto / endInsideFrame",
        ]),
        // An `auto` call the token limit cut. Both end `length` without a
        // finished call; withheld, the unfinished frame is returned as answer text.
        ("length, no call | length, no call, the frame as text", [
            "Bonsai 2 / auto / cut", "Nemotron 3.5 Lightning / auto / cut",
        ]),
        // MiMo refuses both, but a withheld `auto` frame as a generation
        // failure, not the model's noncompliance.
        ("refused (tool_noncompliance: unterminated) | refused (generationFailed)", [
            "MiMo V2.6 / auto / endInsideFrame",
        ]),
        ("refused (tool_noncompliance: malformed) | refused (generationFailed)", [
            "MiMo V2.6 / auto / repeatedArgument",
        ]),
    ].flatMap { outcomes, cells in cells.map { ($0, outcomes) } })

    /// Which paths the two clients of one family and tool choice take.
    enum Paths: String, Sendable {
        /// The streaming client's calls stream and the other's are withheld:
        /// the only cells that compare the two paths.
        case compared
        /// Both clients' calls stream: a framed family's `auto` calls leave
        /// as fragments on any surface that renders them.
        case streamedOnly
        /// Both clients' calls are withheld: the family streams nothing.
        case withheldOnly
        /// Refused before any output: the family's default parser admits no
        /// forced call (`ToolChoiceEnforcementPolicy.validateParser`).
        case refused
    }

    static func pair(_ family: Family, _ choice: Choice) -> String { "\(family.name) / \(choice.rawValue)" }

    /// Family and tool choice pairs whose two clients take one path, or
    /// none. Their cells compare nothing, so they are not part of the
    /// agreement test or its count. Every other pair is `compared`.
    static let singlePath: [String: Paths] = Dictionary(uniqueKeysWithValues: [
        (Paths.streamedOnly, [
            "Gemma 4 / auto", "Gemma 4 text / auto", "GPT-OSS / auto", "Qwen 3.5 and 3.8 dense / auto",
            "Qwen 3.5 and 3.6 MoE / auto", "Qwen3-VL / auto",
        ]),
        (.withheldOnly, [
            "Qwen 4 / auto", "Qwen 4 / required", "Qwen 4 / named",
            "Qwen 4 text / auto", "Qwen 4 text / required", "Qwen 4 text / named",
            "diffusion Gemma / auto", "diffusion Gemma / required", "diffusion Gemma / named",
            "Flint / auto", "Flint / required", "Flint / named",
        ]),
        (.refused, ["Qwen3-VL / required", "Qwen3-VL / named"]),
    ].flatMap { paths, pairs in pairs.map { ($0, paths) } })

    static func paths(_ family: Family, _ choice: Choice) -> Paths {
        singlePath[pair(family, choice)] ?? .compared
    }

    /// The paths two responses to the same request took.
    static func paths(streaming: Outcome, notStreaming: Outcome) -> Paths? {
        switch (streaming.streamsCalls, notStreaming.streamsCalls) {
        case (true?, false?): .compared
        case (true?, true?): .streamedOnly
        case (false?, false?): .withheldOnly
        case (nil, nil): .refused
        default: nil
        }
    }

    @Test("every served model type has a row, and 200 of its 360 cells compare the two paths")
    func everyServedTypeHasARow() {
        #expect(Set(Self.families.map(\.type)) == Set(ServedModelType.allCases))
        var cells: [Paths: Set<String>] = [:]
        for family in Self.families {
            for choice in Choice.allCases {
                for scenario in Scenario.allCases {
                    cells[Self.paths(family, choice), default: []].insert(Self.cell(family, choice, scenario))
                }
            }
        }
        #expect(cells[.compared]?.count == 200)
        #expect(cells[.streamedOnly]?.count == 48)
        #expect(cells[.withheldOnly]?.count == 96)
        #expect(cells[.refused]?.count == 16)
        let pairs = Set(Self.families.flatMap { family in Choice.allCases.map { Self.pair(family, $0) } })
        #expect(Set(Self.singlePath.keys).isSubset(of: pairs), "a listed pair is not in the matrix")
        #expect(Set(Self.knownDivergences.keys).isSubset(of: cells[.compared] ?? []),
            "a listed cell does not compare the two paths")
    }

    @Test("where the two clients take different paths, the paths end alike, except the listed cells",
          arguments: families)
    func streamedAndWithheldAgree(family: Family) async {
        for choice in Choice.allCases where Self.paths(family, choice) == .compared {
            for scenario in Scenario.allCases {
                let cell = Self.cell(family, choice, scenario)
                let streamed = await Self.serve(family, choice, scenario, clientStreams: true)
                let withheld = await Self.serve(family, choice, scenario, clientStreams: false)
                #expect(Self.paths(streaming: streamed, notStreaming: withheld) == .compared,
                    "\(cell) no longer compares the two paths: list it in singlePath")
                let pinned = Self.knownDivergences[cell]
                if streamed == withheld {
                    #expect(pinned == nil, "\(cell) agrees now (\(streamed)): remove it from knownDivergences")
                } else {
                    #expect(pinned == "\(streamed) | \(withheld)",
                        "\(cell): streamed \(streamed), withheld \(withheld)")
                }
            }
        }
    }

    /// Not an agreement of two paths: one path serves both clients, and the
    /// client's own `stream` changes nothing else about the response.
    @Test("where both clients take one path, it is the listed one and serves them alike", arguments: families)
    func singlePathPairsTakeTheListedPath(family: Family) async {
        for choice in Choice.allCases {
            let listed = Self.paths(family, choice)
            guard listed != .compared else { continue }
            for scenario in Scenario.allCases {
                let cell = Self.cell(family, choice, scenario)
                let streaming = await Self.serve(family, choice, scenario, clientStreams: true)
                let notStreaming = await Self.serve(family, choice, scenario, clientStreams: false)
                #expect(Self.paths(streaming: streaming, notStreaming: notStreaming) == listed, "\(cell)")
                #expect(streaming == notStreaming, "\(cell): \(streaming), \(notStreaming)")
            }
        }
    }

    /// Forced choices a family refuses before any output, never counted as
    /// served.
    static let refusedBeforeOutput = Set(singlePath.filter { $0.value == .refused }.keys)

    @Test("a complete call is one finished call for both clients", arguments: families)
    func completeCallsFinish(family: Family) async {
        for choice in Choice.allCases {
            let refused = Self.refusedBeforeOutput.contains(Self.pair(family, choice))
            for clientStreams in [true, false] {
                let served = await Self.serve(family, choice, .complete, clientStreams: clientStreams)
                let cell = "\(family.name) / \(choice.rawValue), client streams: \(clientStreams): \(served)"
                if refused {
                    #expect(served.refusal == "invalidToolPayload", "\(cell)")
                } else {
                    #expect(served == Outcome(calls: [#"get_weather{"city":"Paris"}"#], finishReason: "tool_calls")
                            && served.refusal == nil, "\(cell)")
                }
            }
        }
    }

    /// Families that refuse an `auto` call that breaks only its schema.
    /// Flint's parser reads its frame against the schema and its native
    /// check fails the response; in production it always samples under its
    /// native protocol constraint (`ToolConstraintFactory`), which the canned
    /// output here does not pass through.
    static let schemaBreaksRefused: [String: String] = ["Flint": "refused (generationFailed)"]

    /// Without `strict`, an `auto` call that breaks only its schema is the
    /// model's call: returned as generated, never its markup as text or a
    /// failure, whichever path serves it.
    @Test("an `auto` call that breaks only its schema is returned to both clients, except by the listed families",
          arguments: families)
    func schemaBreaksAreCalls(family: Family) async {
        for clientStreams in [true, false] {
            let served = await Self.serve(family, .auto, .schemaBreak, clientStreams: clientStreams)
            #expect("\(served)" == Self.schemaBreaksRefused[family.name] ?? #"tool_calls, get_weather{"note":"x"}"#,
                "\(family.name), client streams: \(clientStreams)")
        }
    }

    // MARK: - Recorded differences between owners and families

    /// Lightning and Super write the same frame and parse it with the same
    /// parser, on two owners. Where they end the same output differently,
    /// the cell is listed with Lightning's outcome, then Super's.
    static let knownOwnerDivergences: [String: String] = Dictionary(uniqueKeysWithValues: [
        // An `auto` frame the parser refuses, or one left open at the end.
        // Super's owner refuses it (`Failure.malformedToolFrame`); the
        // scheduler's router does not count a Nemotron parse failure
        // (`NativeToolStreamRouter.hasNativeToolFailure`), so Lightning
        // returns the frame as answer text.
        ("stop, no call, the frame as text | refused (tool_noncompliance: native_output)", [
            "streamed / auto / malformed", "withheld / auto / malformed", "withheld / auto / repeatedArgument",
            "withheld / auto / endInsideFrame",
        ]),
        // At a cut Super drops the unfinished frame; Lightning returns it as text.
        ("length, no call, the frame as text | length, no call", ["withheld / auto / cut"]),
    ].flatMap { outcomes, cells in cells.map { ($0, outcomes) } })

    @Test("Lightning's and Super's owners end the same Nemotron output alike, except the listed cells")
    func nemotronOwnersAgree() async throws {
        let lightning = try #require(Self.families.first { $0.type == .nemotronH })
        let superOwner = try #require(Self.families.first { $0.type == .nemotronHOmni })
        for clientStreams in [true, false] {
            for choice in Choice.allCases {
                for scenario in Scenario.allCases {
                    let cell = "\(clientStreams ? "streamed" : "withheld") / \(choice.rawValue) / \(scenario.rawValue)"
                    let scheduler = await Self.serve(lightning, choice, scenario, clientStreams: clientStreams)
                    let owner = await Self.serve(superOwner, choice, scenario, clientStreams: clientStreams)
                    let pinned = Self.knownOwnerDivergences[cell]
                    if scheduler == owner {
                        #expect(pinned == nil, "\(cell) agrees now (\(owner)): remove it from knownOwnerDivergences")
                    } else {
                        #expect(pinned == "\(scheduler) | \(owner)", "\(cell): Lightning \(scheduler), Super \(owner)")
                    }
                }
            }
        }
    }

    /// An `auto` call to a function the request did not declare, without
    /// `strict`: how each family's response ends, to a client that streams.
    /// Only GPT-OSS refuses it by name (`refuseUndeclaredHarmonyCall`).
    /// Nemotron's parser reads the frame and the call is returned as
    /// generated; the other parsers refuse the frame, which MiMo's and
    /// Flint's native check fails and the rest return as answer text.
    static let undeclaredAutoCalls: [String: String] = Dictionary(uniqueKeysWithValues: [
        ("refused (tool_noncompliance: undeclared_name)", ["GPT-OSS"]),
        (#"tool_calls, delete_files{"path":"/"}"#, ["Nemotron 3.5 Lightning", "Nemotron 3.5 Super"]),
        ("refused (generationFailed)", ["MiMo V2.6", "Flint"]),
        ("stop, no call, the frame as text", [
            "Gemma 4", "Gemma 4 text", "Qwen 3.5 and 3.8 dense", "Qwen 3.5 and 3.6 MoE", "Qwen3-VL", "Bonsai 2",
            "GLM-5.3-Flash", "Qwen 4", "Qwen 4 text", "diffusion Gemma",
        ]),
    ].flatMap { outcome, families in families.map { ($0, outcome) } })

    @Test("an `auto` call to an undeclared function ends as listed for each family")
    func undeclaredAutoCallsPerFamily() async {
        for family in Self.families {
            let served = await Self.serve(family, .auto, .undeclaredFunction, clientStreams: true)
            #expect(Self.undeclaredAutoCalls[family.name] == "\(served)", "\(family.name): \(served)")
        }
    }

    /// Owners that record no tool-call tally for a response that returns a
    /// call (`EngineV2RequestUsageSignal.recordToolCalls`). The tally feeds
    /// the terminal profile, which is platform contract, so the gap is
    /// recorded here, not closed.
    static let ownersWithoutAToolCallTally: Set<String> = ["Nemotron 3.5 Super"]

    @Test("every owner tallies the calls it returns, except the listed ones", arguments: families)
    func returnedCallsAreTallied(family: Family) async {
        for clientStreams in [true, false] {
            let served = await Self.serve(family, .auto, .complete, clientStreams: clientStreams)
            let untallied = Self.ownersWithoutAToolCallTally.contains(family.name)
            #expect(served.tally == (untallied ? nil : ToolCallTally(returned: 1, breakingDeclaration: 0)),
                "\(family.name), client streams \(clientStreams): \(String(describing: served.tally))")
        }
    }

    /// Streamed cells of the prompt-forced families (no sampler grammar
    /// holds their frames) that `QwenCallEndGuard` does not cover: it takes
    /// forced calls of the Qwen 3.5 types alone. When the model ends its turn
    /// inside such a call, the call is refused after its name left.
    static let streamedWithoutACallEndGuard: Set<String> = [
        "Qwen 3.5 and 3.8 dense / auto", "Qwen 3.5 and 3.6 MoE / auto",
        "Bonsai 2 / auto", "Bonsai 2 / required", "Bonsai 2 / named",
        "MiMo V2.6 / auto", "MiMo V2.6 / required", "MiMo V2.6 / named",
        "Nemotron 3.5 Lightning / auto", "Nemotron 3.5 Lightning / required", "Nemotron 3.5 Lightning / named",
        "GLM-5.3-Flash / auto", "GLM-5.3-Flash / required", "GLM-5.3-Flash / named",
    ]

    @Test("the call-end guard covers forced Qwen 3.5-family calls; the listed streamed cells have none")
    func callEndGuardCoverage() async throws {
        var listed = Self.streamedWithoutACallEndGuard
        for family in Self.families where family.owner == .scheduler {
            for choice in Choice.allCases {
                let cell = "\(family.name) / \(choice.rawValue)"
                let modelType = family.type.rawValue
                let request = try ProviderLoop.decodeOpenAIRequest(Self.body(family, choice, clientStreams: true))
                guard let prepared = try? ToolChoicePromptPolicy.prepare(request, modelType: modelType),
                    let parser = try? ServerToolParser.resolve(requested: nil, modelType: modelType)
                else {
                    #expect(!listed.contains(cell), "\(cell) is not served")
                    continue
                }
                let guarded = QwenCallEndGuard.isCandidate(
                    prepared: prepared, parser: parser, modelType: modelType, enabled: true)
                #expect(guarded == ([.qwen35, .qwen35MoE].contains(family.type) && choice != .auto), "\(cell)")
                guard listed.remove(cell) != nil else { continue }
                #expect(!guarded, "\(cell) has a guard now: remove it from streamedWithoutACallEndGuard")
                let stopped = await Self.serve(family, choice, .endInsideFrame, clientStreams: true)
                #expect(stopped.refusal == "tool_noncompliance" && stopped.check == "unterminated",
                    "\(cell): \(stopped)")
            }
        }
        #expect(listed.isEmpty, "not in the matrix: \(listed.sorted())")
    }
}

private extension JSONEncoder {
    static var sortedKeys: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
#endif
