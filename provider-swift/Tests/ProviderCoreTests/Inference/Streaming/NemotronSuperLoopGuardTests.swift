// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Streams one clause verbatim, one token per delta. A cancel ends the row
/// with the engine's `.cancelled` terminal; a row nobody cancels ends as
/// `.length` after a short wait, like a row that reached its cap.
private final class SuperLoopingEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<CBv2Event>.Continuation?
    private var cancels = 0
    private var promptTokens = 0
    let tokens: Int

    init(tokens: Int) { self.tokens = tokens }

    var cancelCount: Int { lock.withLock { cancels } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let clause = QwenByteTestTokenizer.tokens("Wait, the reaction is: CO + Cu -> CO2 + Cu (No). ")
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        lock.withLock {
            self.continuation = continuation
            promptTokens = request.promptTokens.count
        }
        for index in 0..<tokens {
            let token = clause[index % clause.count]
            continuation.yield(.delta(
                text: String(decoding: QwenByteTestTokenizer.piece(token), as: UTF8.self),
                tokens: [token], logprobs: nil))
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.finish(.length)
        }
        return stream
    }

    private func finish(_ reason: CBv2FinishReason) {
        let (continuation, prompt) = lock.withLock {
            defer { self.continuation = nil }
            return (self.continuation, promptTokens)
        }
        continuation?.yield(.finished(
            reason: reason, usage: CBv2Usage(promptTokens: prompt, completionTokens: tokens)))
        continuation?.finish()
    }

    func cancel(_ id: CBv2RequestID) {
        lock.withLock { cancels += 1 }
        finish(.cancelled)
    }

    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }

    func shutdown() async {}
}

/// Super's markers in a byte-spelled test vocabulary below Super's 131,072
/// (the binding refuses ids outside it).
private enum SuperThoughtVocabulary {
    static let think = 1012
    static let thinkClose = 1013
    static let imEnd = 1011
    static let markers: [(String, Int)] = [("<think>", think), ("</think>", thinkClose), ("<|im_end|>", imEnd)]
    static let tokenizer = GemmaThoughtTestTokenizer(markers: markers)
    static func tokens(_ text: String) -> [Int] { GemmaThoughtTestTokenizer.tokens(text, markers: markers) }
    /// Super's generation prompt with thinking on: the thought is open.
    static let thinkingPrompt = tokens("<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\n<think>\n")
}

/// A Super row that repeats one clause verbatim inside the thought its prompt
/// opened, one token per delta; the guard's cancel ends it `.cancelled`. Any
/// later submission is the continuation: it answers "Answer: B" and stops.
private final class SuperThoughtLoopEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<CBv2Event>.Continuation] = []
    private var submitted: [CBv2Request] = []
    private var produced: [[Int]] = []

    var requests: [CBv2Request] { lock.withLock { submitted } }
    var outputs: [[Int]] { lock.withLock { produced } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        let index = lock.withLock {
            submitted.append(request)
            continuations.append(continuation)
            produced.append([])
            return submitted.count - 1
        }
        func emit(_ text: String) {
            let tokens = SuperThoughtVocabulary.tokens(text)
            lock.withLock { produced[index] += tokens }
            continuation.yield(.delta(text: text, tokens: tokens, logprobs: nil))
        }
        if index == 0 {
            let clause = Array("Wait, the reaction is: CO + Cu -> CO2 + Cu (No). ")
            for position in 0..<4_200 { emit(String(clause[position % clause.count])) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.finish(index, .length)
            }
        } else {
            for character in "Answer: B" { emit(String(character)) }
            finish(index, .stop)
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
        let index = lock.withLock { submitted.lastIndex { $0.id == id } }
        if let index { finish(index, .cancelled) }
    }

    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }

    func shutdown() async {}
}

private actor SuperLoopEvents {
    var text = ""
    var stopReason: String?
    var completionTokens = 0
    var errors = 0
    func record(_ event: GenerationEvent) {
        switch event {
        case .chunk(let chunk): text += chunk
        case .info(_, let completion, _, let reason):
            stopReason = reason
            completionTokens = completion
        case .error, .terminal: errors += 1
        case .logprobs: break
        }
    }
}

/// review-2005 F1: Super's coordinator and local requests take the owner's
/// own chat route (`NemotronSuperLocalImageHTTP` → `NemotronSuperLocalBinding`),
/// not the scheduler's text path. That route now resolves the same loop guard
/// from its request plan and passes it to the bridge.
@Suite("Loop guard on Super's own text route")
struct NemotronSuperLoopGuardTests {
    private static let defaults = GenerationLoopGuardPolicy.Setting.modelTypes(
        GenerationLoopGuardPolicy.defaultModelTypes)

    private func plan(_ fields: String = "", content: String = "\"hi\"") throws -> NemotronSuperRequestPlan {
        try NemotronSuperRequestPlan(body: Data("""
        {"model":"\(NemotronSuperLocalBinding.modelID)","max_tokens":8192,\
        "messages":[{"role":"user","content":\(content)}]\(fields)}
        """.utf8))
    }

    @Test("a plain text request is guarded, as Super's model type")
    func plainTextIsGuarded() throws {
        let loopGuard = try #require(try plan().loopGuard(setting: Self.defaults))
        #expect(loopGuard.modelType == "nemotron_h_omni")
    }

    @Test("the scheduler's exclusions and switch hold: JSON output, a forced call, media, off, unlisted")
    func exclusionsAndSwitch() throws {
        #expect(try plan(",\"response_format\":{\"type\":\"json_object\"}").loopGuard(setting: Self.defaults) == nil)
        let schema = #","response_format":{"type":"json_schema","json_schema":{"name":"a","schema":{"type":"object"}}}"#
        #expect(try plan(schema).loopGuard(setting: Self.defaults) == nil)
        let tool = #","tools":[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","properties":{}}}}]"#
        #expect(try plan(tool + #","tool_choice":"required""#).loopGuard(setting: Self.defaults) == nil)
        // Tools the model may call: guarded until a tool-call frame appears.
        #expect(try plan(tool).loopGuard(setting: Self.defaults) != nil)
        let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP4z8BAEiJN9aiGUQ1DSgMAkPn/Afnh+ngAAAAASUVORK5CYII="
        let image = #"[{"type":"text","text":"hi"},{"type":"image_url","image_url":{"url":""# + png + #""}}]"#
        #expect(try plan(content: image).loopGuard(setting: Self.defaults) == nil)
        #expect(try plan().loopGuard(setting: .off) == nil)
        #expect(try plan().loopGuard(setting: .modelTypes(["nemotron_h"])) == nil)
    }

    private func serve(_ engine: SuperLoopingEngine, setting: GenerationLoopGuardPolicy.Setting) async throws
        -> SuperLoopEvents {
        let modelID = NemotronSuperLocalBinding.modelID
        let tokenizer = TokenizerHandle(QwenByteTestTokenizer())
        let bridge = EngineV2Bridge(engine: engine, modelId: modelID, tokenizer: tokenizer,
            eosTokenIds: [248046, 248044], defaultMaxTokens: 64, maxConcurrentRequests: 1)
        let binding = NemotronSuperLocalBinding(acquire: { model in
            .init(tokenizer: tokenizer, releaseToken: OneShotRelease(release: { _ in }, modelId: model),
                  engineV2Bridge: bridge)
        })
        let plan = try plan()
        let events = SuperLoopEvents()
        try await binding.run(request: plan.bridgeRequest, promptTokens: [1, 2, 3],
                              loopGuard: plan.loopGuard(setting: setting),
                              onEvent: { await events.record($0) })
        await bridge.shutdown()
        return events
    }

    @Test("a repeating Super answer is stopped in the engine and ends as length, with no error")
    func repeatingAnswerEndsAsLength() async throws {
        let engine = SuperLoopingEngine(tokens: 4_200)
        let events = try await serve(engine, setting: Self.defaults)
        #expect(engine.cancelCount == 1)
        #expect(await events.errors == 0)
        #expect(await events.stopReason == "length")
        #expect(await events.completionTokens == 4_200)
        // Every token's text reaches the client, the in-flight ones after the stop included.
        #expect(await events.text.hasPrefix("Wait, the reaction is:"))
        #expect(await events.text.utf8.count > 4_096)
    }

    // MARK: Ending a repeating thought

    private static let exitDefaults = GenerationLoopExitThinkingPolicy.Setting.modelTypes(
        GenerationLoopExitThinkingPolicy.defaultModelTypes)

    @Test("Super's exit is `</think>` alone, as its template writes a thought; its prompt opens the thought")
    func superExit() throws {
        let plan = try plan()
        let exit = try #require(plan.exitThinking(
            promptTokens: SuperThoughtVocabulary.thinkingPrompt, tokenizer: SuperThoughtVocabulary.tokenizer,
            setting: Self.exitDefaults))
        #expect(exit.exitTokens == [SuperThoughtVocabulary.thinkClose])
        #expect(exit.exitText == "</think>")
        #expect(exit.startsInside)
        // Thinking off: the prompt closed an empty thought.
        let off = SuperThoughtVocabulary.tokens("<|im_start|>assistant\n<think></think>")
        #expect(plan.exitThinking(promptTokens: off, tokenizer: SuperThoughtVocabulary.tokenizer,
                                  setting: Self.exitDefaults)?.startsInside == false)
        // Never with logprobs; the env list can leave Super's off.
        #expect(try self.plan(",\"logprobs\":true,\"top_logprobs\":2").exitThinking(
            promptTokens: SuperThoughtVocabulary.thinkingPrompt, tokenizer: SuperThoughtVocabulary.tokenizer,
            setting: Self.exitDefaults) == nil)
        #expect(plan.exitThinking(
            promptTokens: SuperThoughtVocabulary.thinkingPrompt, tokenizer: SuperThoughtVocabulary.tokenizer,
            setting: .modelTypes(["gemma4", "gemma4_text", "qwen3_5_moe"])) == nil)
        // The guard carries it.
        let loopGuard = try #require(plan.loopGuard(setting: Self.defaults, exitThinking: exit))
        #expect(loopGuard.exitThinking?.record === exit.record)
    }

    @Test("a repeating Super thought ends in an answer on the owner's route; a stop in the answer is the request's")
    func superThoughtLoopEndsInAnAnswer() async throws {
        let engine = SuperThoughtLoopEngine()
        let modelID = NemotronSuperLocalBinding.modelID
        let tokenizer = TokenizerHandle(SuperThoughtVocabulary.tokenizer)
        let bridge = EngineV2Bridge(engine: engine, modelId: modelID, tokenizer: tokenizer,
            eosTokenIds: [SuperThoughtVocabulary.imEnd], defaultMaxTokens: 64, maxConcurrentRequests: 1)
        let binding = NemotronSuperLocalBinding(acquire: { model in
            .init(tokenizer: tokenizer, releaseToken: OneShotRelease(release: { _ in }, modelId: model),
                  engineV2Bridge: bridge)
        })
        let plan = try plan(#","stop":["B"]"#)
        let prompt = SuperThoughtVocabulary.thinkingPrompt
        let exit = plan.exitThinking(promptTokens: prompt, tokenizer: SuperThoughtVocabulary.tokenizer,
                                     setting: Self.exitDefaults)
        let usage = EngineV2RequestUsageSignal()
        let events = SuperLoopEvents()
        try await binding.run(request: plan.bridgeRequest, promptTokens: prompt, usageSignal: usage,
                              loopGuard: plan.loopGuard(setting: Self.defaults, exitThinking: exit),
                              onEvent: { await events.record($0) })
        await bridge.shutdown()
        let requests = engine.requests
        #expect(requests.count == 2)
        let first = try #require(requests.first)
        let continuation = try #require(requests.last)
        let firstOutput = try #require(engine.outputs.first)
        // The same prompt, every token the row produced, then `</think>`.
        #expect(continuation.promptTokens == first.promptTokens + firstOutput + [SuperThoughtVocabulary.thinkClose])
        #expect(continuation.maxTokens == first.maxTokens - firstOutput.count - 1)
        #expect(continuation.stopStrings == ["B"])
        #expect(await events.errors == 0)
        #expect(await events.text.hasSuffix("</think>Answer: B"))
        #expect(await events.stopReason == "stop")
        #expect(await events.completionTokens == firstOutput.count + 1 + 9)
        #expect(usage.matchedStopSequence == "B")
    }

    @Test("with the switch off the row runs to the engine's own end")
    func switchOffKeepsTodaysBehavior() async throws {
        let engine = SuperLoopingEngine(tokens: 4_200)
        let events = try await serve(engine, setting: .off)
        #expect(engine.cancelCount == 0)
        #expect(await events.stopReason == "length")
    }
}
