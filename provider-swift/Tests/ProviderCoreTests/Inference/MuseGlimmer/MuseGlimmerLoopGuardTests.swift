// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// ASCII bytes plus Muse Glimmer's control tokens and the header pieces its
/// vocabulary holds as one token, with their real ids
/// (`<|eom|><|start|>assistant to=user<|message|>` is
/// [200007, 200022, 140680, 328, 76976, 200023] in the pinned tokenizer).
struct MuseGlimmerTestTokenizer: MLXLMCommon.Tokenizer {
    static let beginOfText = 200_000
    static let endOfText = 200_001
    static let endOfMessage = 200_007
    static let endOfTurn = 200_008
    static let start = 200_022
    static let message = 200_023
    static let assistant = 140_680
    static let to = 328
    static let user = 76_976
    static let stops: Set<Int> = [endOfText, endOfTurn]
    static let vocabulary: [(String, Int)] = [
        ("<|begin_of_text|>", beginOfText), ("<|end_of_text|>", endOfText), ("<|eom|>", endOfMessage),
        ("<|eot|>", endOfTurn), ("<|start|>", start), ("<|message|>", message),
        ("assistant", assistant), (" to", to), ("=self", 19_669), ("=user", user),
    ]

    var markers = Self.vocabulary
    /// `convertTokenToId` answers for these spellings only (all by default).
    var resolvable: Set<String>?
    /// Spells every text as bytes, control spellings included.
    var spellsControlsAsBytes = false

    static func tokens(_ text: String, markers: [(String, Int)] = vocabulary) -> [Int] {
        let bytes = Array(text.utf8)
        var ids: [Int] = []
        var index = 0
        while index < bytes.count {
            if let marker = markers.first(where: { bytes[index...].starts(with: Array($0.0.utf8)) }) {
                ids.append(marker.1)
                index += marker.0.utf8.count
            } else {
                ids.append(Int(bytes[index]))
                index += 1
            }
        }
        return ids
    }

    /// The served template's shape: a system message, the user's turn, and the
    /// generation prompt `<|start|>assistant`.
    static func prompt(history: String = "") -> String {
        "<|begin_of_text|><|start|>system<|message|>You are a helpful assistant.<|eot|>"
            + "<|start|>user<|message|>hi<|eot|>" + history + "<|start|>assistant"
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        spellsControlsAsBytes ? Array(text.utf8).map(Int.init) : Self.tokens(text, markers: markers)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.compactMap(convertIdToToken).joined()
    }
    func convertTokenToId(_ token: String) -> Int? {
        if let resolvable, !resolvable.contains(token) { return nil }
        return markers.first { $0.0 == token }?.1
    }
    func convertIdToToken(_ id: Int) -> String? {
        if let marker = markers.first(where: { $0.1 == id }) { return marker.0 }
        guard (0..<128).contains(id), let scalar = UnicodeScalar(id) else { return nil }
        return String(Character(scalar))
    }
    var bosToken: String? { "<|begin_of_text|>" }
    var eosToken: String? { "<|eot|>" }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        Self.tokens(Self.prompt(), markers: markers)
    }
}

/// A Muse Glimmer row, one header piece per delta as the real tokenizer splits
/// it (` to`, `=self`, `<|message|>`). A looping row repeats one clause; the
/// guard's cancel ends it `.cancelled` (unless cancelled, it ends `.length`
/// after a short wait). Any later submission is the continuation.
final class MuseGlimmerLoopTestEngine: CBv2Engine, @unchecked Sendable {
    enum Row: Sendable {
        /// The reasoning repeats itself.
        case reasoningLoop
        /// The reasoning ends, then the answer repeats itself.
        case answerLoop
        /// The reasoning ends and the answer follows: the guard never fires.
        case answers
    }

    enum Next: Sendable {
        /// ` to=user<|message|>Answer: B`, then `<|eot|>`.
        case answer
        /// ` to=get_weather<|message|>` and one ATEM call, then `<|eot|>`.
        case call
        /// Another reasoning message, which repeats itself too.
        case reopensReasoning
        /// The answer's text alone, then `<|eot|>`: the exit opened the answer.
        case answerText
    }

    static let clause = Array("We need to check the reservation first. ")
    static let call = "<atem:function_calls>\n<atem:invoke name=\"get_weather\">\n"
        + "<atem:parameter name=\"city\">Paris</atem:parameter>\n</atem:invoke>\n</atem:function_calls>"

    private let lock = NSLock()
    private var continuations: [AsyncStream<CBv2Event>.Continuation] = []
    private var submitted: [CBv2Request] = []
    private var produced: [[Int]] = []
    private var cancels = 0
    let row: Row
    let next: Next

    init(_ row: Row, then next: Next = .answer) {
        self.row = row
        self.next = next
    }

    var requests: [CBv2Request] { lock.withLock { submitted } }
    var outputs: [[Int]] { lock.withLock { produced } }
    var cancelCount: Int { lock.withLock { cancels } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        let index = lock.withLock {
            submitted.append(request)
            continuations.append(continuation)
            produced.append([])
            return submitted.count - 1
        }
        func emit(_ text: String) {
            let tokens = MuseGlimmerTestTokenizer.tokens(text)
            lock.withLock { produced[index] += tokens }
            continuation.yield(.delta(text: text, tokens: tokens, logprobs: nil))
        }
        func header(_ recipient: String) { [" to", "=" + recipient, "<|message|>"].forEach { emit($0) } }
        func nextMessage() { ["<|eom|>", "<|start|>", "assistant"].forEach { emit($0) } }
        func text(_ value: String) { for character in value { emit(String(character)) } }
        func loop() {
            for position in 0..<4_200 { emit(String(Self.clause[position % Self.clause.count])) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.finish(index, .length)
            }
        }
        // The engine suppresses a stop token's text: its delta carries the token only.
        func stop() {
            lock.withLock { produced[index].append(MuseGlimmerTestTokenizer.endOfTurn) }
            continuation.yield(.delta(text: "", tokens: [MuseGlimmerTestTokenizer.endOfTurn], logprobs: nil))
            finish(index, .stop)
        }
        if index == 0 {
            header("self")
            switch row {
            case .reasoningLoop:
                loop()
            case .answerLoop:
                text("ok")
                nextMessage()
                header("user")
                loop()
            case .answers:
                text("ok")
                nextMessage()
                header("user")
                text("Answer: B")
                stop()
            }
        } else {
            switch next {
            case .answer:
                header("user")
                text("Answer: B")
                stop()
            case .call:
                header("get_weather")
                text(Self.call)
                stop()
            case .reopensReasoning:
                header("self")
                loop()
            case .answerText:
                text("Answer: B")
                stop()
            }
        }
        return stream
    }

    private func finish(_ index: Int, _ reason: CBv2FinishReason) {
        let (continuation, prompt, completion) = lock.withLock {
            defer { continuations[index] = AsyncStream<CBv2Event>.makeStream().continuation }
            return (continuations[index], submitted[index].promptTokens.count, produced[index].count)
        }
        continuation.yield(.finished(
            reason: reason, usage: CBv2Usage(promptTokens: prompt, completionTokens: completion)))
        continuation.finish()
    }

    func cancel(_ id: CBv2RequestID) {
        let index = lock.withLock {
            cancels += 1
            return submitted.lastIndex { $0.id == id }
        }
        if let index { finish(index, .cancelled) }
    }

    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }

    func shutdown() async {}
}

/// Muse Glimmer's loop guard and its exit from a repeating reasoning message
/// (Onyx `to=self`): the guard cuts a loop, and the continuation still
/// answers in `content` or with a tool call. Both are off by default for the
/// model until its A/B; these tests turn them on explicitly.
@Suite("Muse Glimmer loop guard and exit from a repeating thought")
struct MuseGlimmerLoopGuardTests {
    private static let modelType = MuseGlimmerModelPolicy.modelType
    private static let modelID = MuseGlimmerModelPolicy.catalogModelID
    private static let tokenizer = MuseGlimmerTestTokenizer()
    private static let prompt = MuseGlimmerTestTokenizer.tokens(MuseGlimmerTestTokenizer.prompt())
    /// `<|eom|><|start|>assistant`.
    private static let exitTokens = [
        MuseGlimmerTestTokenizer.endOfMessage, MuseGlimmerTestTokenizer.start, MuseGlimmerTestTokenizer.assistant]
    /// Without tools: the same, then ` to=user<|message|>`.
    private static let answerExitTokens = exitTokens
        + [MuseGlimmerTestTokenizer.to, MuseGlimmerTestTokenizer.user, MuseGlimmerTestTokenizer.message]
    private static let enabled = GenerationLoopExitThinkingPolicy.Setting.modelTypes([modelType])
    private static let guarded = GenerationLoopGuardPolicy.Setting.modelTypes([modelType])

    private func resolve(
        tokenizer: MuseGlimmerTestTokenizer = Self.tokenizer, prompt: [Int] = Self.prompt,
        logprobs: Bool = false, declaresTools: Bool = true,
        setting: GenerationLoopExitThinkingPolicy.Setting = Self.enabled, finalExit: Bool = true
    ) -> GenerationLoopExitThinking? {
        GenerationLoopExitThinkingPolicy.resolve(
            modelType: Self.modelType, tokenizer: tokenizer, promptTokens: prompt, logprobs: logprobs,
            declaresTools: declaresTools, setting: setting, finalExit: finalExit)
    }

    private static let toolsJSON = #","tools":[{"type":"function","function":{"name":"get_weather","#
        + #""description":"Weather in a city","parameters":{"type":"object","#
        + #""properties":{"city":{"type":"string"}},"required":["city"]}}}]"#

    private func request(_ extra: String = Self.toolsJSON, maxTokens: Int = 8_192) throws -> OpenAIChatCompletionRequest {
        try ProviderLoop.decodeOpenAIRequest(Data("""
        {"model":"\(Self.modelID)","messages":[{"role":"user","content":"hi"}],\
        "temperature":0,"max_tokens":\(maxTokens)\(extra)}
        """.utf8), modelType: Self.modelType)
    }

    // MARK: Policy

    @Test("off by default until the model's A/B: neither the guard nor the exit is in its default list")
    func offByDefault() throws {
        #expect(!GenerationLoopGuardPolicy.defaultModelTypes.contains(Self.modelType))
        #expect(!GenerationLoopExitThinkingPolicy.defaultModelTypes.contains(Self.modelType))
        let request = try request()
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: Self.modelType)
        #expect(GenerationLoopGuardPolicy.resolve(
            modelType: Self.modelType, request: request, prepared: prepared, tokenConstraint: nil,
            setting: .modelTypes(GenerationLoopGuardPolicy.defaultModelTypes)) == nil)
        #expect(resolve(setting: .modelTypes(GenerationLoopExitThinkingPolicy.defaultModelTypes)) == nil)
        // Listed, each resolves; the lists reach the launchd daemon as written.
        for key in [GenerationLoopGuardPolicy.environmentKey, GenerationLoopExitThinkingPolicy.environmentKey] {
            #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
            #expect(LaunchAgent.passthroughEnvironment(from: [key: Self.modelType])[key] == Self.modelType)
        }
        let guardList = GenerationLoopGuardPolicy.setting(
            environment: [GenerationLoopGuardPolicy.environmentKey: Self.modelType])
        #expect(GenerationLoopGuardPolicy.resolve(
            modelType: Self.modelType, request: request, prepared: prepared, tokenConstraint: nil,
            setting: guardList) != nil)
        let exitList = GenerationLoopExitThinkingPolicy.setting(
            environment: [GenerationLoopExitThinkingPolicy.environmentKey: Self.modelType])
        #expect(resolve(setting: exitList) != nil)
    }

    @Test("the guard's call markers are the ATEM frame, with or without declared tools")
    func guardMarkers() throws {
        for extra in [Self.toolsJSON, ""] {
            let request = try request(extra)
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: Self.modelType)
            var loopGuard = try #require(GenerationLoopGuardPolicy.resolve(
                modelType: Self.modelType, request: request, prepared: prepared, tokenConstraint: nil,
                setting: Self.guarded), "\(extra)")
            // A tool channel's frame turns it off: a call's arguments are never cut.
            #expect(loopGuard.observe(text: " to=get_weather<|message|><atem:function", tokens: [1]) == nil)
            #expect(!loopGuard.disarmed)
            #expect(loopGuard.observe(text: "_calls>", tokens: [2]) == nil)
            #expect(loopGuard.disarmed)
            var bare = try #require(GenerationLoopGuardPolicy.resolve(
                modelType: Self.modelType, request: request, prepared: prepared, tokenConstraint: nil,
                setting: Self.guarded))
            #expect(bare.observe(text: "<atem:invoke name=\"get_weather\">", tokens: [3]) == nil)
            #expect(bare.disarmed)
        }
        #expect(GenerationLoopGuardPolicy.museGlimmerToolCallMarkers == ["<atem:function_calls>", "<atem:invoke"])
        // Another tool parser is refused before generation; it gets no guard.
        let hermes = try request(Self.toolsJSON + #","tool_call_parser":"hermes""#)
        #expect(GenerationLoopGuardPolicy.resolve(
            modelType: Self.modelType, request: hermes,
            prepared: try ToolChoicePromptPolicy.prepare(hermes, modelType: Self.modelType), tokenConstraint: nil,
            setting: Self.guarded) == nil)
        // A forced call or a JSON answer gets none either, as for every family.
        let forced = try request(Self.toolsJSON + #","tool_choice":"required""#)
        #expect(GenerationLoopGuardPolicy.resolve(
            modelType: Self.modelType, request: forced,
            prepared: try ToolChoicePromptPolicy.prepare(forced, modelType: Self.modelType), tokenConstraint: nil,
            setting: Self.guarded) == nil)
    }

    @Test("with tools, the exit ends the reasoning message and starts the next assistant message")
    func onyxExit() throws {
        let exit = try #require(resolve(declaresTools: true))
        #expect(exit.exitTokens == Self.exitTokens)
        #expect(exit.exitText == "<|eom|><|start|>assistant")
        #expect(exit.closeToken == MuseGlimmerTestTokenizer.endOfMessage)
        #expect(exit.openMarker == "to=self<|message|>")
        #expect(exit.closeMarker == "<|eom|>")
        // The prompt ends at `<|start|>assistant`: the model opens its reasoning itself.
        #expect(!exit.startsInside)
        // The model then writes ` to=user<|message|>`, where the model's own stop scope opens.
        #expect(exit.answerStopScope == nil)
    }

    @Test("without tools, the exit also opens the answer; its stops apply from the first token")
    func onyxExitWithoutTools() throws {
        let exit = try #require(resolve(declaresTools: false))
        #expect(exit.exitTokens == Self.answerExitTokens)
        #expect(exit.exitText == "<|eom|><|start|>assistant to=user<|message|>")
        #expect(exit.answerStopScope == MuseGlimmerTemplateFix.insideAnswerStopScope)
        // GPT-OSS's switch is GPT-OSS's alone.
        #expect(resolve(declaresTools: false, finalExit: false)?.exitText == exit.exitText)
        let scope = MuseGlimmerTemplateFix.insideAnswerStopScope
        let answer = StopHoldback(stopStrings: ["B"], scope: scope).ingest("Answer: B")
        #expect(answer.stopped)
        #expect(answer.text == "Answer: ")
        // Text after the message ends is not the answer.
        let later = StopHoldback(stopStrings: ["B"], scope: scope)
            .ingest("Answer<|eom|><|start|>assistant to=self<|message|>B")
        #expect(!later.stopped)
        // The model's own scope waits for a header the exit already fed: it would never match.
        #expect(!StopHoldback(stopStrings: ["B"], scope: MuseGlimmerTemplateFix.answerStopScope)
            .ingest("Answer: B").stopped)
    }

    @Test("a prompt that ends inside a reasoning message starts inside; a closed one does not")
    func promptTail() throws {
        let history = "<|start|>assistant to=self<|message|>Look.<|eom|>"
            + "<|start|>assistant to=user<|message|>Done.<|eot|><|start|>user<|message|>again<|eot|>"
        let closed = MuseGlimmerTestTokenizer.tokens(MuseGlimmerTestTokenizer.prompt(history: history))
        #expect(try #require(resolve(prompt: closed)).startsInside == false)
        let open = MuseGlimmerTestTokenizer.tokens(MuseGlimmerTestTokenizer.prompt() + " to=self<|message|>")
        #expect(try #require(resolve(prompt: open)).startsInside)
    }

    @Test("never with logprobs; the control tokens must be fed as themselves")
    func controlTokensAndLogprobs() {
        #expect(resolve(logprobs: true) == nil)
        var spelled = Self.tokenizer
        spelled.spellsControlsAsBytes = true
        #expect(resolve(tokenizer: spelled) == nil)
        #expect(resolve(tokenizer: spelled, declaresTools: false) == nil)
        for control in ["<|eom|>", "<|start|>"] {
            var missing = Self.tokenizer
            missing.resolvable = Set(MuseGlimmerTestTokenizer.vocabulary.map(\.0)).subtracting([control])
            #expect(resolve(tokenizer: missing) == nil, "\(control)")
        }
        // The answer exit also feeds `<|message|>` as itself.
        var noMessage = Self.tokenizer
        noMessage.resolvable = Set(MuseGlimmerTestTokenizer.vocabulary.map(\.0)).subtracting(["<|message|>"])
        #expect(resolve(tokenizer: noMessage, declaresTools: false) == nil)
        #expect(resolve(tokenizer: noMessage, declaresTools: true) != nil)
    }

    // MARK: The guard over scripted deltas

    private func loopGuard(_ exit: GenerationLoopExitThinking?) -> GenerationLoopGuard {
        GenerationLoopGuard(
            modelType: Self.modelType,
            toolCallMarkers: GenerationLoopGuardPolicy.genericToolCallMarkers
                + GenerationLoopGuardPolicy.museGlimmerToolCallMarkers,
            exitThinking: exit)
    }

    private func pieces(_ texts: [String]) -> [(String, [Int])] {
        texts.map { ($0, MuseGlimmerTestTokenizer.tokens($0)) }
    }

    private func clause(_ count: Int) -> [(String, [Int])] {
        let block = Array(900..<917)
        return (0..<count).map { ("w", [block[$0 % block.count]]) }
    }

    private func run(
        _ deltas: [(String, [Int])], into loopGuard: inout GenerationLoopGuard
    ) -> GenerationLoopDetector.Detection? {
        for (text, tokens) in deltas {
            if let detection = loopGuard.observe(text: text, tokens: tokens) { return detection }
        }
        return nil
    }

    private static let reasoning = [" to", "=self", "<|message|>"]
    private static let answerHeader = ["<|eom|>", "<|start|>", "assistant", " to", "=user", "<|message|>"]

    @Test("a loop inside the reasoning message is cut and asks to end the thought")
    func loopInsideReasoning() throws {
        let exit = try #require(resolve())
        var loopGuard = loopGuard(exit)
        let detection = run(pieces(Self.reasoning) + clause(8_000), into: &loopGuard)
        #expect(detection != nil)
        #expect(loopGuard.endsThought)
        #expect(exit.record.requested == detection)
    }

    @Test("a loop in the answer is cut as length, with no exit")
    func loopInAnswer() throws {
        let exit = try #require(resolve())
        var answerGuard = loopGuard(exit)
        #expect(run(pieces(Self.reasoning + ["ok"] + Self.answerHeader) + clause(8_000), into: &answerGuard) != nil)
        #expect(!answerGuard.endsThought)
        #expect(exit.record.requested == nil)
        // Without an exit at all (the default), a loop is still cut.
        var plain = loopGuard(nil)
        #expect(run(pieces(Self.reasoning) + clause(8_000), into: &plain) != nil)
    }

    @Test("an `<|eom|>` in the stopping delta, or in flight after the stop, keeps the stop a length")
    func reasoningClosedByTheRow() throws {
        let after = try #require(resolve())
        var closed = loopGuard(after)
        #expect(run(pieces(Self.reasoning) + clause(8_000), into: &closed) != nil)
        #expect(closed.endsThought)
        #expect(!after.record.closedAfterStop)
        #expect(closed.observe(text: "<|eom|>", tokens: [MuseGlimmerTestTokenizer.endOfMessage]) == nil)
        #expect(after.record.closedAfterStop)
    }

    // MARK: Serving (scheduler text path, the real bridge, a scripted engine)

    private struct Outcome {
        var chunks: [String] = []
        var content = ""
        var reasoning = ""
        var calls: [ToolCall] = []
        var info: ServerGenerationInfo?
        var error: (any Error)?
        var loopGuardStops: [Bool?] = []
    }

    private final class TelemetrySink: @unchecked Sendable {
        private let lock = NSLock()
        private var received: [TelemetryEvent] = []
        func add(_ event: TelemetryEvent) { lock.withLock { received.append(event) } }
        var loopGuardStops: [Bool?] {
            lock.withLock {
                received.filter { $0.fields?["operation"]?.description == "engine_v2_loop_guard" }
                    .map { $0.fields?["ends_thought"]?.value as? Bool }
            }
        }
    }

    private func serve(
        _ engine: MuseGlimmerLoopTestEngine, maxTokens: Int = 8_192, extra: String = Self.toolsJSON,
        guardSetting: GenerationLoopGuardPolicy.Setting = Self.guarded,
        exitSetting: GenerationLoopExitThinkingPolicy.Setting = Self.enabled
    ) async throws -> Outcome {
        let telemetry = TelemetrySink()
        let handle = TokenizerHandle(Self.tokenizer)
        // The model's own stop tokens and stop scope, as `ModelEOSPolicy` gives a Muse slot.
        let bridge = EngineV2Bridge(engine: engine, modelId: Self.modelID, tokenizer: handle,
            eosTokenIds: MuseGlimmerTestTokenizer.stops, stopStringScope: MuseGlimmerTemplateFix.answerStopScope,
            defaultMaxTokens: 64, maxConcurrentRequests: 1, emitTelemetry: { telemetry.add($0) })
        var scheduler = MultiModelBatchSchedulerEngine(registryProvider: {
            [Self.modelID: .init(tokenizer: handle, modelType: Self.modelType, engineV2Bridge: bridge)]
        })
        // The switches as a clean process would read them, whatever this process's environment says.
        scheduler.loopGuardSetting = guardSetting
        scheduler.exitThinkingSetting = exitSetting
        let request = try request(extra, maxTokens: maxTokens)
        var outcome = Outcome()
        do {
            for try await event in try await scheduler.streamChatCompletion(request: request) {
                switch event {
                case .content(let text):
                    outcome.chunks.append(text)
                    outcome.content += text
                case .parsed(let parsed):
                    outcome.content += parsed.content
                    outcome.reasoning += parsed.reasoningContent ?? ""
                case .info(let info): outcome.info = info
                case .toolCall(let call): outcome.calls.append(call)
                case .toolCallDelta(let delta): if let call = delta.completed { outcome.calls.append(call) }
                case .logprobs: break
                }
            }
        } catch { outcome.error = error }
        await bridge.shutdown()
        outcome.loopGuardStops = telemetry.loopGuardStops
        return outcome
    }

    private static let loopText = String(MuseGlimmerLoopTestEngine.clause)

    private func framingFree(_ text: String) -> Bool {
        !["<|", "|>", "to=self", "to=user", "<atem:"].contains { text.contains($0) }
    }

    @Test("with tools: a reasoning loop is cut, the thought ends, and the answer arrives as content")
    func reasoningLoopEndsInAnAnswer() async throws {
        let engine = MuseGlimmerLoopTestEngine(.reasoningLoop, then: .answer)
        let outcome = try await serve(engine)
        #expect(outcome.error == nil)
        #expect(engine.cancelCount == 1)
        let requests = engine.requests
        #expect(requests.count == 2)
        let first = try #require(requests.first)
        let continuation = try #require(requests.last)
        let rowOutput = try #require(engine.outputs.first)
        let answerOutput = try #require(engine.outputs.last)
        // The same prompt, every token the row produced, then `<|eom|><|start|>assistant`.
        #expect(continuation.promptTokens == first.promptTokens + rowOutput + Self.exitTokens)
        #expect(continuation.maxTokens == first.maxTokens - rowOutput.count - Self.exitTokens.count)
        #expect(continuation.sampling.temperature == first.sampling.temperature)
        // The model's own stop scope: the continuation writes the answer's header itself.
        #expect(continuation.stopStringScope == MuseGlimmerTemplateFix.answerStopScope)
        // Admitted ahead of the queue (#2100).
        #expect(first.priority == 0)
        #expect(continuation.priority == LoopExitThinkingContinuation.admissionPriority)
        #expect(outcome.reasoning.hasPrefix(Self.loopText))
        #expect(framingFree(outcome.reasoning))
        #expect(outcome.content == "Answer: B")
        #expect(outcome.calls.isEmpty)
        #expect(outcome.info?.stopReason == "stop")
        #expect(outcome.info?.promptTokens == first.promptTokens.count)
        #expect(outcome.info?.completionTokens == rowOutput.count + Self.exitTokens.count + answerOutput.count)
        #expect(outcome.loopGuardStops == [true])
    }

    @Test("with tools: a tool call after the exit is parsed, and nothing leaks as content")
    func toolCallAfterTheExit() async throws {
        let engine = MuseGlimmerLoopTestEngine(.reasoningLoop, then: .call)
        let outcome = try await serve(engine)
        #expect(outcome.error == nil)
        #expect(engine.requests.count == 2)
        #expect(outcome.calls.count == 1)
        let call = try #require(outcome.calls.first)
        #expect(call.function.name == "get_weather")
        #expect(call.function.arguments == ["city": .string("Paris")])
        #expect(outcome.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(outcome.reasoning.hasPrefix(Self.loopText))
        #expect(framingFree(outcome.reasoning))
        #expect(outcome.info?.stopReason == "stop")
        #expect(outcome.loopGuardStops == [true])
    }

    @Test("without tools: the exit opens the answer, the answer is content, the stops apply inside it")
    func reasoningLoopWithoutTools() async throws {
        let engine = MuseGlimmerLoopTestEngine(.reasoningLoop, then: .answerText)
        let outcome = try await serve(engine, extra: "")
        #expect(outcome.error == nil)
        let first = try #require(engine.requests.first)
        let continuation = try #require(engine.requests.last)
        let rowOutput = try #require(engine.outputs.first)
        #expect(continuation.promptTokens == first.promptTokens + rowOutput + Self.answerExitTokens)
        #expect(continuation.stopStringScope == MuseGlimmerTemplateFix.insideAnswerStopScope)
        #expect(outcome.content == "Answer: B")
        #expect(outcome.reasoning.hasPrefix(Self.loopText))
        #expect(framingFree(outcome.reasoning))
        #expect(outcome.info?.stopReason == "stop")
        #expect(outcome.loopGuardStops == [true])
        // A client stop string reaches the continuation, scoped to the answer the exit opened.
        // The engine applies it (this test engine does not); `onyxExitWithoutTools` checks the scope.
        let stopEngine = MuseGlimmerLoopTestEngine(.reasoningLoop, then: .answerText)
        let stopped = try await serve(stopEngine, extra: #","stop":["B"]"#)
        #expect(stopped.error == nil)
        #expect(stopEngine.requests.count == 2)
        #expect(stopEngine.requests.last?.stopStrings == ["B"])
        #expect(stopEngine.requests.last?.stopStringScope == MuseGlimmerTemplateFix.insideAnswerStopScope)
    }

    @Test("a continuation that reopens its reasoning and loops ends as length, with no second exit")
    func reopenedReasoningEndsAsLength() async throws {
        let engine = MuseGlimmerLoopTestEngine(.reasoningLoop, then: .reopensReasoning)
        let outcome = try await serve(engine, maxTokens: 16_384)
        #expect(outcome.error == nil)
        #expect(engine.requests.count == 2)
        #expect(engine.cancelCount == 2)
        #expect(outcome.info?.stopReason == "length")
        #expect(outcome.content.isEmpty)
        #expect(outcome.loopGuardStops == [true, false])
    }

    @Test("guard on, exit off (the default exit): the loop is cut as length and nothing else is submitted")
    func guardWithoutExit() async throws {
        let engine = MuseGlimmerLoopTestEngine(.reasoningLoop)
        let outcome = try await serve(engine, exitSetting: .modelTypes(GenerationLoopExitThinkingPolicy.defaultModelTypes))
        #expect(outcome.error == nil)
        #expect(engine.requests.count == 1)
        #expect(engine.cancelCount == 1)
        #expect(outcome.info?.stopReason == "length")
        #expect(outcome.content.isEmpty)
        #expect(outcome.loopGuardStops == [false])
    }

    @Test("the defaults (guard and exit off): the loop runs to its own end, unguarded, as before")
    func defaultsLeaveTheRowUnguarded() async throws {
        let engine = MuseGlimmerLoopTestEngine(.reasoningLoop)
        let outcome = try await serve(
            engine, guardSetting: .modelTypes(GenerationLoopGuardPolicy.defaultModelTypes),
            exitSetting: .modelTypes(GenerationLoopExitThinkingPolicy.defaultModelTypes))
        #expect(outcome.error == nil)
        #expect(engine.requests.count == 1)
        #expect(engine.cancelCount == 0)
        #expect(outcome.info?.stopReason == "length")
        #expect(outcome.loopGuardStops.isEmpty)
    }

    @Test("an answer that ends by itself is untouched with both on")
    func cleanAnswerUntouched() async throws {
        let engine = MuseGlimmerLoopTestEngine(.answers)
        let outcome = try await serve(engine)
        #expect(outcome.error == nil)
        #expect(engine.requests.count == 1)
        #expect(engine.cancelCount == 0)
        #expect(outcome.reasoning == "ok")
        #expect(outcome.content == "Answer: B")
        #expect(outcome.info?.stopReason == "stop")
        #expect(outcome.loopGuardStops.isEmpty)
    }

    @Test("the real tokenizer spells both exits as the template does",
          .enabled(if: ProcessInfo.processInfo.environment["MUSE_GLIMMER_NVFP4_DIR"] != nil,
                   "set MUSE_GLIMMER_NVFP4_DIR to the pinned tokenizer directory"))
    func realTokenizerExits() async throws {
        let directory = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["MUSE_GLIMMER_NVFP4_DIR"]), isDirectory: true)
        let tokenizer = try await LocalTokenizerLoader(environment: [:]).load(from: directory)
        let prompt = tokenizer.encode(
            text: "<|begin_of_text|><|start|>user<|message|>hi<|eot|><|start|>assistant", addSpecialTokens: false)
        let withTools = try #require(GenerationLoopExitThinkingPolicy.resolve(
            modelType: Self.modelType, tokenizer: tokenizer, promptTokens: prompt, logprobs: false,
            declaresTools: true, setting: Self.enabled))
        #expect(withTools.exitTokens == Self.exitTokens)
        let withoutTools = try #require(GenerationLoopExitThinkingPolicy.resolve(
            modelType: Self.modelType, tokenizer: tokenizer, promptTokens: prompt, logprobs: false,
            declaresTools: false, setting: Self.enabled))
        #expect(withoutTools.exitTokens == Self.answerExitTokens)
        // The template's own spelling of the same header.
        #expect(tokenizer.encode(text: "<|start|>assistant to=user<|message|>", addSpecialTokens: false)
            == Array(Self.answerExitTokens.dropFirst()))
        #expect(tokenizer.encode(text: " to=self<|message|>", addSpecialTokens: false) == [328, 19_669, 200_023])
    }

    // MARK: Mac B's GPQA run, replayed

    /// One draw of Mac B's run through the production guard.
    private struct ReplayedDraw {
        let id: String
        let tokens: Int
        let detection: GenerationLoopDetector.Detection?
        let endsThought: Bool
        let exitRequested: Bool
        /// When the cut would have come, from the draw's own delta rate.
        let seconds: Double?
    }

    private func chunks(_ tokens: [Int], of size: Int = 4) -> [[Int]] {
        stride(from: 0, to: tokens.count, by: size).map { Array(tokens[$0..<min($0 + size, tokens.count)]) }
    }

    /// Mac B's full GPQA run (594 draws, effort medium, 8 rows, the defaults:
    /// no guard). q101-e0 and q173-e0 repeated a reasoning phrase with no
    /// answer until the client's 3,600 s wall, each holding a row for an hour.
    /// Each draw is what its client received, spelled back into the raw output
    /// (` to=self<|message|>` reasoning, then
    /// `<|eom|><|start|>assistant to=user<|message|>` answer `<|eot|>`) and
    /// retokenized with the pinned tokenizer. The tokens approximate the
    /// generated ones; several reasoning messages read as one.
    @Test("Mac B's GPQA loopers are cut inside the thought long before the client's wall, and no other draw is",
          .enabled(if: ProcessInfo.processInfo.environment["MUSE_GLIMMER_NVFP4_DIR"] != nil
                       && ProcessInfo.processInfo.environment["MUSE_GLIMMER_LOOP_RECEIPTS"] != nil,
                   "set MUSE_GLIMMER_NVFP4_DIR and MUSE_GLIMMER_LOOP_RECEIPTS (Mac B's gpqa-pM/pM.jsonl)"))
    func macBGPQAReplay() async throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try #require(environment["MUSE_GLIMMER_NVFP4_DIR"]), isDirectory: true)
        let tokenizer = try await LocalTokenizerLoader(environment: [:]).load(from: directory)
        let lines = try String(contentsOfFile: try #require(environment["MUSE_GLIMMER_LOOP_RECEIPTS"]), encoding: .utf8)
            .split(separator: "\n")
        let receipts = try lines.map { line in
            try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        #expect(receipts.count == 594)
        // GPQA declares no tools: the exit also writes the answer's header (`museOnyxToAnswer`).
        let request = try request("")
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: Self.modelType)
        // At the defaults, as Mac B ran, there is no guard: each loop ran to the wall.
        #expect(GenerationLoopGuardPolicy.resolve(
            modelType: Self.modelType, request: request, prepared: prepared, tokenConstraint: nil,
            setting: GenerationLoopGuardPolicy.setting(environment: [:])) == nil)
        let prompt = tokenizer.encode(
            text: "<|begin_of_text|><|start|>user<|message|>hi<|eot|><|start|>assistant", addSpecialTokens: false)
        func spell(_ text: String) -> [Int] { tokenizer.encode(text: text, addSpecialTokens: false) }
        let reasoningHeader = spell(" to=self<|message|>")
        let answerHeader = spell("<|eom|><|start|>assistant to=user<|message|>")
        let endOfTurn = spell("<|eot|>")
        var draws: [ReplayedDraw] = []
        for receipt in receipts {
            let id = try #require(receipt["id"] as? String)
            let content = receipt["content"] as? String ?? ""
            // Headers and control tokens one at a time, text in deltas of four tokens.
            var deltas = reasoningHeader.map { [$0] } + chunks(spell(receipt["reasoning"] as? String ?? ""))
            if !content.isEmpty {
                deltas += answerHeader.map { [$0] } + chunks(spell(content)) + endOfTurn.map { [$0] }
            }
            let exit = try #require(GenerationLoopExitThinkingPolicy.resolve(
                modelType: Self.modelType, tokenizer: tokenizer, promptTokens: prompt, logprobs: false,
                declaresTools: false, setting: Self.enabled))
            var loopGuard = try #require(GenerationLoopGuardPolicy.resolve(
                modelType: Self.modelType, request: request, prepared: prepared, tokenConstraint: nil,
                setting: Self.guarded, exitThinking: exit))
            var detection: GenerationLoopDetector.Detection?
            for delta in deltas where detection == nil {
                detection = loopGuard.observe(
                    text: tokenizer.decode(tokenIds: delta, skipSpecialTokens: false), tokens: delta)
            }
            let tokens = deltas.reduce(0) { $0 + $1.count }
            var seconds: Double?
            if let detection, let send = receipt["t_send"] as? Double, let first = receipt["t_first"] as? Double,
               let last = receipt["t_last"] as? Double, last > first {
                seconds = first - send + Double(detection.generatedTokens) * (last - first) / Double(tokens)
            }
            draws.append(ReplayedDraw(
                id: id, tokens: tokens, detection: detection, endsThought: loopGuard.endsThought,
                exitRequested: exit.record.requested != nil, seconds: seconds))
        }
        let walled = Set(receipts.filter { $0["aborted"] as? String == "wall" }.compactMap { $0["id"] as? String })
        #expect(walled == ["q101-e0", "q173-e0"])
        for draw in draws where walled.contains(draw.id) {
            let detection = try #require(draw.detection, "\(draw.id) is never cut")
            // Inside the reasoning message: the thought ends and the answer is asked for.
            #expect(draw.endsThought && draw.exitRequested, "\(draw.id)")
            // Long before the wall: within the first quarter of the hour's tokens, and of the hour.
            #expect(detection.generatedTokens * 4 < draw.tokens, "\(draw.id)")
            #expect((draw.seconds ?? .infinity) < 900, "\(draw.id)")
        }
        let wronglyCut = draws.filter { !walled.contains($0.id) && $0.detection != nil }.map(\.id)
        #expect(wronglyCut.isEmpty, "the guard would cut \(wronglyCut)")
        let checked = draws.filter { $0.tokens >= GenerationLoopDetector.Thresholds().minTokens }
        var report = ["id\ttokens\tcut_at_token\tperiod\tspan\tends_thought\tseconds"]
        for draw in draws where draw.detection != nil || walled.contains(draw.id) {
            report.append([draw.id, "\(draw.tokens)", draw.detection.map { "\($0.generatedTokens)" } ?? "-",
                           draw.detection.map { "\($0.period)" } ?? "-", draw.detection.map { "\($0.span)" } ?? "-",
                           "\(draw.endsThought)", draw.seconds.map { String(format: "%.0f", $0) } ?? "-"]
                .joined(separator: "\t"))
        }
        report.append("# \(draws.count) draws; \(checked.count) reach the guard's first check; "
            + "\(wronglyCut.count) cut outside the walled draws; longest other draw "
            + "\(draws.filter { !walled.contains($0.id) }.map(\.tokens).max() ?? 0) tokens")
        print(report.map { "loop-replay: " + $0 }.joined(separator: "\n"))
    }
}
