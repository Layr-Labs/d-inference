import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// Production native constraint over a CPU-only byte vocabulary: four terminal
/// tokens, every single byte (id 4 + byte), then explicit multi-byte pieces.
private struct FlintStopFixture {
    let request: OpenAIChatCompletionRequest
    let prepared: ToolChoicePromptPolicy.Prepared
    let constraint: FlintAnswerStopConstraint
    private let extras: [String]

    init(stops: [String], choice: String = "\"auto\"", extras: [String] = [], maxTokens: Int = 512) throws {
        request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data("""
        {"model":"test/flint","messages":[{"role":"user","content":"hi"}],"max_tokens":\(maxTokens),
         "tool_choice":\(choice),"tools":[{"type":"function","function":{"name":"weather",
         "parameters":{"type":"object","properties":{"city":{"type":"string"}}}}}]}
        """.utf8))
        prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "flint")
        self.extras = extras
        let terminals = ["<|end_of_text|>", "<|user|>", "<|observation|>", "<|developer|>"]
        let pieces = terminals.map { Array($0.utf8) } + (0...255).map { [UInt8($0)] } + extras.map { Array($0.utf8) }
        let vocabulary = FlintNativeVocabulary(pieces: pieces, stopTokenIDs: [0, 1, 2, 3],
            answerStops: [0, 1], observationStop: 2, fallbackTokenID: 0)
        let base = try FlintNativeProtocolConstraint(mode: prepared.mode, maxTokens: maxTokens,
            vocabulary: vocabulary, allowsParallel: prepared.allowsParallelCalls,
            allowedToolNames: prepared.allowedToolNames, tools: prepared.tools?.map { $0.toolSpec() })
        constraint = FlintAnswerStopConstraint(base: base, vocabulary: vocabulary, stops: FlintAnswerStops(stops))
    }

    func ids(_ text: String) -> [Int] { text.utf8.map { 4 + Int($0) } }
    func extra(_ piece: String) -> Int { 260 + extras.firstIndex(of: piece)! }
    func piece(_ id: Int) -> [UInt8] { id < 260 ? [UInt8(id - 4)] : Array(extras[id - 260].utf8) }

    func walk(_ text: String, from initial: Int = 0) -> Int? {
        var state = initial
        for id in ids(text) {
            guard let next = constraint.nextState(state: state, tokenID: id) else { return nil }
            state = next
        }
        return state
    }

    func decode(_ script: [Int]) -> FlintScriptedDecode {
        FlintScriptedDecode(constraint: constraint, script: script, stopTokens: [0, 1, 2, 3],
            maxTokens: request.maxTokens ?? 512, piece: piece)
    }
}

/// Model stand-in that honors the actual constraint masks: it samples the
/// script's next token when allowed, otherwise (or once the script ends) the
/// first allowed stop token, and detokenizes with UTF-8 holdback like CBv2.
private struct FlintScriptedDecode {
    var deltas: [(text: String, token: Int)] = []
    var finish = "length"

    init(constraint: (any CBv2TokenConstraint)?, script: [Int], stopTokens: Set<Int>, maxTokens: Int,
         piece: (Int) -> [UInt8]) {
        var state = constraint?.initialState ?? 0
        var pending: [UInt8] = []
        var remaining = script.makeIterator()
        while deltas.count < maxTokens {
            let wanted = remaining.next()
            let token: Int?
            if let constraint {
                let allowed = constraint.allowedTokenIDs(state: state, remainingTokens: maxTokens - deltas.count)
                token = wanted.flatMap { allowed.contains($0) ? $0 : nil } ?? allowed.first(where: stopTokens.contains)
            } else {
                token = wanted ?? stopTokens.min()
            }
            guard let token else { finish = "invalid"; return }
            if let constraint {
                guard let next = constraint.nextState(state: state, tokenID: token) else { finish = "invalid"; return }
                state = next
            }
            if stopTokens.contains(token) {
                deltas.append(("", token))
                finish = "stop"
                return
            }
            pending += piece(token)
            deltas.append((Self.drainCompleteUTF8(&pending), token))
        }
    }

    var events: [GenerationEvent] {
        deltas.compactMap { $0.text.isEmpty ? nil : GenerationEvent.chunk($0.text) }
            + [.info(promptTokens: 1, completionTokens: deltas.count, tokensPerSecond: 0, finishReason: finish)]
    }

    private static func drainCompleteUTF8(_ bytes: inout [UInt8]) -> String {
        guard !bytes.isEmpty else { return "" }
        var end = bytes.count
        for back in 1...min(3, bytes.count) {
            let byte = bytes[bytes.count - back]
            guard byte & 0xC0 == 0x80 else {
                let width = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                if back < width { end = bytes.count - back }
                break
            }
        }
        defer { bytes.removeFirst(end) }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}

private struct FlintStreamOutcome {
    var content = ""
    var contentDeltas: [String] = []
    var reasoning = ""
    var calls: [ToolCall] = []
    var info: ServerGenerationInfo?

    mutating func record(_ event: MLXServerGenerationEvent) {
        switch event {
        case .content(let text):
            content += text
            contentDeltas.append(text)
        case .parsed(let parsed):
            if !parsed.content.isEmpty {
                content += parsed.content
                contentDeltas.append(parsed.content)
            }
            reasoning += parsed.reasoningContent ?? ""
        case .toolCall(let call): calls.append(call)
        case .toolCallDelta(let delta): if let call = delta.completed { calls.append(call) }
        case .info(let info): self.info = info
        }
    }
}

@Suite("Flint answer stop sequences")
struct FlintAnswerStopTests {
    // MARK: Token constraint

    @Test func matchedAnswerAllowsOnlyAnswerEOSEvenAfterAnOpenedFrameInTheSameToken() throws {
        let fixture = try FlintStopFixture(stops: ["END"], extras: ["D<tool_call>wea", "D<think>"])
        let constraint = fixture.constraint
        let matched = try #require(fixture.walk("Answer END"))
        #expect(constraint.allowedTokenIDs(state: matched, remainingTokens: 10) == [0, 1])
        #expect(constraint.nextState(state: matched, tokenID: 0) == -1)
        #expect(constraint.nextState(state: matched, tokenID: 1) == -1)
        #expect(constraint.nextState(state: matched, tokenID: 2) == nil)
        #expect(constraint.nextState(state: matched, tokenID: 4 + 32) == nil)

        // Bytes after the match are discarded output, so a call they open is
        // never entered; tokens the native protocol rejects stay rejected.
        let prefix = try #require(fixture.walk("Answer EN"))
        let trailing = try #require(constraint.nextState(state: prefix, tokenID: fixture.extra("D<tool_call>wea")))
        #expect(constraint.allowedTokenIDs(state: trailing, remainingTokens: 10) == [0, 1])
        #expect(constraint.nextState(state: prefix, tokenID: fixture.extra("D<think>")) == nil)
        #expect(!constraint.allowedTokenIDs(state: prefix, remainingTokens: 10).contains(fixture.extra("D<think>")))
    }

    @Test func reasoningAndToolArgumentsNeverAdvanceAMatch() throws {
        let fixture = try FlintStopFixture(stops: ["END"])
        let constraint = fixture.constraint
        let reasoning = try #require(fixture.walk("<think>END and END"))
        for stop in 0...3 { #expect(constraint.nextState(state: reasoning, tokenID: stop) == nil) }
        let answer = try #require(fixture.walk("</think>Open", from: reasoning))
        #expect(constraint.allowedTokenIDs(state: answer, remainingTokens: 10).count > 2)
        let call = "<tool_call>weather<arg_key>city</arg_key><arg_value>END</arg_value></tool_call>"
        let afterCall = try #require(fixture.walk("Checking. " + call))
        #expect(constraint.nextState(state: afterCall, tokenID: 2) == -1)
        #expect(constraint.nextState(state: afterCall, tokenID: 0) == nil)

        // Forced calls have no answer channel, so stops are inert there.
        let required = try FlintStopFixture(stops: ["END"], choice: "\"required\"")
        let state = try #require(required.walk(call))
        #expect(required.constraint.nextState(state: state, tokenID: 2) == -1)
        #expect(required.walk("END") == nil)
        #expect(required.constraint.nextState(state: 0, tokenID: 0) == nil)
    }

    @Test func masksAgreeWithTransitionsAndAnswerProgressReusesStates() throws {
        let fixture = try FlintStopFixture(stops: ["END", "E<"], extras: ["ND", "D<tool_call>"])
        let constraint = fixture.constraint
        for path in ["", "E", "Answer EN", "Answer E", "x <", "<think>EN", "<think>x</think>E",
                     "<tool_call>weather<arg_key>city</arg_key><arg_value>EN", "Answer END"] {
            let state = try #require(fixture.walk(path), "\(path)")
            let allowed = constraint.allowedTokenIDs(state: state, remainingTokens: 100)
            #expect(allowed == Array(Set(allowed)).sorted())
            for token in 0..<262 {
                #expect(allowed.contains(token) == (constraint.nextState(state: state, tokenID: token) != nil),
                    "\(path) token \(token)")
            }
        }
        let fresh = try FlintStopFixture(stops: ["END", "E<"])
        let start = try #require(fresh.walk("Answer "))
        var state = start
        for _ in 0..<2_000 { state = try #require(fresh.walk("EN EX E <x <tool ", from: state)) }
        #expect(state == start)
        #expect(fresh.constraint.cachedStateCount < 64)
    }

    @Test func maskCacheKeysFollowTheReturnedMasks() throws {
        let fixture = try FlintStopFixture(stops: ["END"])
        let constraint = fixture.constraint
        #expect(constraint.allowsChainedDecode)
        var masksByKey: [Int: [Int]] = [:]
        for path in ["", "Answer", "Answer E", "Answer EN", "Answer END", "<think>EN", "<think>x</think>E"] {
            let state = try #require(fixture.walk(path), "\(path)")
            #expect(constraint.maskCacheKey(state: state, remainingTokens: 0) == nil)
            let key = try #require(constraint.maskCacheKey(state: state, remainingTokens: 10), "\(path)")
            let allowed = constraint.allowedTokenIDs(state: state, remainingTokens: 10)
            if let known = masksByKey[key] { #expect(known == allowed, "\(path)") } else { masksByKey[key] = allowed }
        }
        #expect(masksByKey[-1] == [0, 1])
    }

    // MARK: Stream filter

    @Test func holdbackIsMinimalFlushesNonMatchesAndCutsAtTheEarliestStart() throws {
        let fixture = try FlintStopFixture(stops: ["END", "aab"])
        var filter = fixture.constraint.makeStreamFilter()
        #expect(filter.ingest("Hello EN") == "Hello ")
        #expect(filter.ingest("X") == "ENX")
        #expect(filter.ingest(" aE") == " a")
        #expect(filter.finish() == "E")
        #expect(filter.matchedSequence == nil)

        var overlap = fixture.constraint.makeStreamFilter()
        #expect(overlap.ingest("xaaa") == "xa")
        #expect(overlap.ingest("b tail") == "")
        #expect(overlap.matchedSequence == "aab")
        #expect(overlap.ingest("more") == "")
        #expect(overlap.finish() == "")

        // Reasoning passes through immediately; only answer bytes are held.
        var reasoning = fixture.constraint.makeStreamFilter()
        #expect(reasoning.ingest("<think>END EN") == "<think>END EN")
        #expect(reasoning.ingest("D</think>EN") == "D</think>")
        #expect(reasoning.ingest("D") == "")
        #expect(reasoning.matchedSequence == "END")
    }

    @Test func undecidedMarkerBytesCommitBeforeMatchingOrOpenAFrame() throws {
        let fixture = try FlintStopFixture(stops: ["a<"])
        var literal = fixture.constraint.makeStreamFilter()
        #expect(literal.ingest("xa<") == "x")
        #expect(literal.ingest("b") == "")
        #expect(literal.matchedSequence == "a<")

        var atEnd = fixture.constraint.makeStreamFilter()
        #expect(atEnd.ingest("xa<") == "x")
        #expect(atEnd.finish() == "")
        #expect(atEnd.matchedSequence == "a<")

        let frame = "xa<tool_call>weather<arg_key>city</arg_key><arg_value>a<b</arg_value></tool_call>"
        var call = fixture.constraint.makeStreamFilter()
        #expect(call.ingest(frame) == frame)
        #expect(call.finish() == "")
        #expect(call.matchedSequence == nil)
    }

    @Test func holdbackStaysBoundedByTheLongestSequence() throws {
        let stop = String(repeating: "a", count: 255) + "b"
        let fixture = try FlintStopFixture(stops: [stop])
        var filter = fixture.constraint.makeStreamFilter()
        var released = 0
        for _ in 0..<100 { released += filter.ingest(String(repeating: "a", count: 100)).utf8.count }
        #expect(released == 10_000 - 255)
        #expect(filter.ingest("b") == "")
        #expect(filter.matchedSequence == stop)
    }

    @Test func leadingAnswerWhitespaceIsVisibleButMatchesNeverSpanReasoning() throws {
        let fixture = try FlintStopFixture(stops: ["\n\n"])
        var spanning = fixture.constraint.makeStreamFilter()
        let text = "\n<think>r\n\n</think>\nA"
        #expect(spanning.ingest(text) + spanning.finish() == text)
        #expect(spanning.matchedSequence == nil)

        var leading = fixture.constraint.makeStreamFilter()
        #expect(leading.ingest("\n\n<think>") == "")
        #expect(leading.matchedSequence == "\n\n")
    }

    // MARK: Constraint, filter and stream router together

    #if DEBUG
    private func stream(_ fixture: FlintStopFixture, _ run: FlintScriptedDecode)
        async throws -> (FlintStreamOutcome, EngineV2RequestUsageSignal) {
        let usage = EngineV2RequestUsageSignal()
        let events = run.events
        let upstream = AsyncStream<GenerationEvent> { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
        let handler = try ToolStreamPreparation.makeHandler(
            request: fixture.request, prepared: fixture.prepared, modelType: "flint")
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: { [:] })
        let output = try scheduler._testMakeEventStream(upstream: upstream, cancelUpstream: {},
            prepared: fixture.prepared, releaseBox: OneShotRelease(release: { _ in }, modelId: "fixture"),
            toolHandler: handler, nativeReasoningPrefix: "<think></think>", usageSignal: usage,
            answerStopFilter: fixture.constraint.makeStreamFilter())
        var outcome = FlintStreamOutcome()
        for try await event in output { outcome.record(event) }
        return (outcome, usage)
    }

    @Test func contentStopEndsWithStopStripsTheSequenceAndCountsSampledTokens() async throws {
        let fixture = try FlintStopFixture(stops: ["END"])
        let run = fixture.decode(fixture.ids("<think>plan END</think>Answer END tail"))
        // The engine samples through the match, then one constrained EOS.
        #expect(run.deltas.count == fixture.ids("<think>plan END</think>Answer END").count + 1)
        #expect(run.deltas.last?.token == 0)
        let (outcome, usage) = try await stream(fixture, run)
        #expect(outcome.content == "Answer ")
        #expect(outcome.contentDeltas.allSatisfy { !$0.contains("E") })
        #expect(outcome.reasoning == "plan END")
        #expect(outcome.calls.isEmpty)
        #expect(outcome.info?.stopReason == "stop")
        #expect(outcome.info?.completionTokens == run.deltas.count)
        #expect(usage.matchedStopSequence == "END")
    }

    @Test func stopTextInReasoningAndToolArgumentsIsOrdinaryOutput() async throws {
        let fixture = try FlintStopFixture(stops: ["END"])
        let call = "<tool_call>weather<arg_key>city</arg_key><arg_value>END</arg_value></tool_call>"
        let run = fixture.decode(fixture.ids("<think>END END</think>Checking. " + call) + [2])
        #expect(run.finish == "stop")
        let (outcome, usage) = try await stream(fixture, run)
        #expect(outcome.reasoning == "END END")
        #expect(outcome.content == "Checking. ")
        #expect(outcome.calls.count == 1)
        #expect(outcome.calls.first?.function.arguments["city"] == .string("END"))
        #expect(outcome.info?.stopReason == "stop")
        #expect(outcome.info?.completionTokens == run.deltas.count)
        #expect(usage.matchedStopSequence == nil)
    }

    @Test func stopsSplitAcrossTokensDeltasAndScalarsNeverLeak() async throws {
        let fixture = try FlintStopFixture(stops: ["END", "終わ"], extras: ["EN", "D<tool_call>wea"])
        let pieces = fixture.ids("Answer ") + [fixture.extra("EN"), fixture.extra("D<tool_call>wea")]
            + fixture.ids("ther<arg_key>city</arg_key><arg_value>x</arg_value></tool_call>")
        let split = fixture.decode(pieces)
        #expect(split.deltas.count == fixture.ids("Answer ").count + 3)
        let (cut, usage) = try await stream(fixture, split)
        #expect(cut.content == "Answer ")
        #expect(cut.calls.isEmpty)
        #expect(cut.info?.stopReason == "stop")
        #expect(usage.matchedStopSequence == "END")

        let scalar = fixture.decode(fixture.ids("答え終わりです"))
        let (unicode, _) = try await stream(fixture, scalar)
        #expect(unicode.content == "答え")
        #expect(unicode.info?.completionTokens == "答え終わ".utf8.count + 1)

        let miss = fixture.decode(fixture.ids("Answer ENX done"))
        let (flushed, missUsage) = try await stream(fixture, miss)
        #expect(flushed.content == "Answer ENX done")
        #expect(flushed.info?.stopReason == "stop")
        #expect(missUsage.matchedStopSequence == nil)
    }

    @Test func matchOnTheLastBudgetedTokenStillReportsStop() async throws {
        let fixture = try FlintStopFixture(stops: ["END"], maxTokens: 6)
        let run = fixture.decode(fixture.ids("abcEND"))
        #expect(run.finish == "length")
        let (outcome, usage) = try await stream(fixture, run)
        #expect(outcome.content == "abc")
        #expect(outcome.info?.stopReason == "stop")
        #expect(outcome.info?.completionTokens == 6)
        #expect(usage.matchedStopSequence == "END")
    }
    #endif

    // MARK: Admission

    private func factoryRequest(stop: [String]) throws -> OpenAIChatCompletionRequest {
        var request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data("""
        {"model":"test/flint","messages":[{"role":"user","content":"hi"}],"max_tokens":100}
        """.utf8))
        request.stop = stop
        return request
    }

    private func make(_ request: OpenAIChatCompletionRequest, type: String = "flint") throws
        -> (any CBv2TokenConstraint)? {
        try ToolConstraintFactory.make(prepared: ToolChoicePromptPolicy.prepare(request, modelType: type),
            request: request, tokenizer: TokenizerHandle(FlintProtocolTestTokenizer()),
            modelContext: .init(modelId: request.model, modelType: type), defaultMaxTokens: 100,
            stopTokenIDs: [150001, 150003, 150005, 150018], nativePromptTokens: [150004])
    }

    @Test func sequenceLimitsMatchTheOtherNativeConstraints() throws {
        let wide = String(repeating: "é", count: 128)
        #expect(try make(factoryRequest(stop: [wide, wide, wide, "a"])) is FlintAnswerStopConstraint)
        #expect(try make(factoryRequest(stop: ["", ""])) is FlintNativeProtocolConstraint)
        for stop in [["a", "b", "c", "d", "e"], [wide + "x"], [String(repeating: "x", count: 257)]] {
            #expect(throws: MultiModelBatchSchedulerEngineError.self) { try make(factoryRequest(stop: stop)) }
        }
        // Empty strings are ignored before counting, as for Gemma.
        #expect(try make(factoryRequest(stop: ["", "a", "b", "c", "d"])) is FlintAnswerStopConstraint)
    }

    @Test func otherFamiliesKeepEngineStopStrings() throws {
        let request = try factoryRequest(stop: ["END"])
        for type in ["other", "Flint", " flint "] {
            #expect(try make(request, type: type) == nil)
        }
        let translated = MultiModelBatchSchedulerEngine.translate(openAIRequest: request, defaultMaxTokens: 1)
        #expect(translated.stop?.asArray == ["END"])
        let native = MultiModelBatchSchedulerEngine.translate(openAIRequest: request, defaultMaxTokens: 1,
            engineStopStrings: false)
        #expect(native.stop == nil)
    }
}

// MARK: - Serving path

/// Flint markers as special tokens, single bytes at ids 0...255 (byte-level
/// spelling), and "x" elsewhere; enough for the real vocabulary contract.
private struct FlintByteTestTokenizer: MLXLMCommon.Tokenizer {
    private static let byteSpelling: [UInt8: String] = {
        var spelling = [UInt8: String]()
        for value in UInt32(0)..<512 {
            let text = String(Character(Unicode.Scalar(value)!))
            if let bytes = FlintNativeVocabulary.bytes(text), bytes.count == 1 { spelling[bytes[0]] = text }
        }
        return spelling
    }()

    static func piece(_ id: Int) -> [UInt8] {
        if let marker = FlintNativeVocabulary.markers.first(where: { $0.1 == id }) { return Array(marker.0.utf8) }
        return id < 256 ? [UInt8(id)] : Array("x".utf8)
    }

    static func tokens(_ text: String) -> [Int] {
        let bytes = Array(text.utf8)
        var ids: [Int] = []
        var index = 0
        while index < bytes.count {
            if let marker = FlintNativeVocabulary.markers.first(where: {
                bytes[index...].starts(with: Array($0.0.utf8))
            }) {
                ids.append(marker.1)
                index += marker.0.utf8.count
            } else {
                ids.append(Int(bytes[index]))
                index += 1
            }
        }
        return ids
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { Self.tokens(text) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        String(decoding: tokenIds.flatMap(Self.piece), as: UTF8.self)
    }
    func convertTokenToId(_ token: String) -> Int? {
        FlintNativeVocabulary.markers.first { $0.0 == token }?.1
    }
    func convertIdToToken(_ id: Int) -> String? {
        guard (0..<150144).contains(id) else { return nil }
        if let marker = FlintNativeVocabulary.markers.first(where: { $0.1 == id }) { return marker.0 }
        return id < 256 ? Self.byteSpelling[UInt8(id)] : "x"
    }
    var bosToken: String? { "<|begin_of_text|>" }
    var eosToken: String? { "<|end_of_text|>" }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] { [150004] }
}

/// Records each submission and samples a fixed script through its constraint.
private final class FlintScriptedStopEngine: CBv2Engine, @unchecked Sendable {
    private let script: [Int]
    private let lock = NSLock()
    private var requests: [CBv2Request] = []
    private var sampled = 0

    init(script: String) { self.script = FlintByteTestTokenizer.tokens(script) }

    var submitted: [CBv2Request] { lock.withLock { requests } }
    var sampledTokens: Int { lock.withLock { sampled } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let run = FlintScriptedDecode(constraint: request.tokenConstraint, script: script,
            stopTokens: request.stopTokens, maxTokens: request.maxTokens, piece: FlintByteTestTokenizer.piece)
        lock.withLock {
            requests.append(request)
            sampled += run.deltas.count
        }
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        for delta in run.deltas {
            continuation.yield(.delta(text: delta.text, tokens: [delta.token], logprobs: nil))
        }
        continuation.yield(.finished(reason: run.finish == "length" ? .length : .stop,
            usage: CBv2Usage(promptTokens: request.promptTokens.count, completionTokens: run.deltas.count)))
        continuation.finish()
        return stream
    }

    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}
}

@Suite("Flint answer stops through the scheduler and bridge")
struct FlintAnswerStopServingTests {
    private let modelID = "test/flint-stop"

    private func serve(_ engine: FlintScriptedStopEngine, modelType: String, fields: String) async throws
        -> (FlintStreamOutcome, EngineV2RequestUsageSignal) {
        let tokenizer = TokenizerHandle(FlintByteTestTokenizer())
        let bridge = EngineV2Bridge(engine: engine, modelId: modelID, tokenizer: tokenizer,
            eosTokenIds: [150001], extraEOSTokens: ["<|user|>", "<|observation|>", "<|developer|>"],
            defaultMaxTokens: 64, maxConcurrentRequests: 1)
        let usage = EngineV2RequestUsageSignal()
        let id = modelID
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: {
            [id: .init(tokenizer: tokenizer, modelType: modelType, engineV2Bridge: bridge)]
        }, engineV2Usage: usage)
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data("""
        {"model":"\(modelID)","messages":[{"role":"user","content":"hi"}],"max_tokens":64,\(fields)}
        """.utf8))
        var outcome = FlintStreamOutcome()
        do {
            for try await event in try await scheduler.streamChatCompletion(request: request) {
                outcome.record(event)
            }
        } catch {
            await bridge.shutdown()
            throw error
        }
        await bridge.shutdown()
        return (outcome, usage)
    }

    private let tools = #""tools":[{"type":"function","function":{"name":"weather","parameters":{"type":"object","properties":{"city":{"type":"string"}}}}}]"#

    @Test func flintStopsBypassEngineMatchingAndEndOnlyTheVisibleAnswer() async throws {
        let engine = FlintScriptedStopEngine(script: "<think>plan END</think>Answer END tail")
        let (outcome, usage) = try await serve(engine, modelType: "flint",
            fields: #""stop":["END"],"# + tools)
        let request = try #require(engine.submitted.first)
        #expect(request.stopStrings.isEmpty)
        #expect(request.tokenConstraint is FlintAnswerStopConstraint)
        #expect(outcome.reasoning == "plan END")
        #expect(outcome.content == "Answer ")
        #expect(outcome.calls.isEmpty)
        #expect(outcome.info?.stopReason == "stop")
        #expect(outcome.info?.completionTokens == engine.sampledTokens)
        #expect(engine.sampledTokens == FlintByteTestTokenizer.tokens("<think>plan END</think>Answer END").count + 1)
        #expect(usage.matchedStopSequence == "END")
    }

    @Test func flintToolArgumentsKeepStopText() async throws {
        let engine = FlintScriptedStopEngine(script:
            "<tool_call>weather<arg_key>city</arg_key><arg_value>END</arg_value></tool_call><|observation|>")
        let (outcome, usage) = try await serve(engine, modelType: "flint",
            fields: #""stop":["END"],"tool_choice":"required","# + tools)
        #expect(engine.submitted.first?.stopStrings.isEmpty == true)
        #expect(outcome.calls.first?.function.arguments["city"] == .string("END"))
        #expect(outcome.content.isEmpty)
        #expect(outcome.info?.stopReason == "stop")
        #expect(usage.matchedStopSequence == nil)
    }

    @Test func otherFamiliesStillHandStopsToTheEngine() async throws {
        let engine = FlintScriptedStopEngine(script: "plain")
        _ = try await serve(engine, modelType: "other", fields: #""stop":["END"]"#)
        let request = try #require(engine.submitted.first)
        #expect(request.stopStrings == ["END"])
        #expect(request.tokenConstraint == nil)
    }
}
