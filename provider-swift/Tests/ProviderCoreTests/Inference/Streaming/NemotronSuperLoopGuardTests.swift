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

    @Test("with the switch off the row runs to the engine's own end")
    func switchOffKeepsTodaysBehavior() async throws {
        let engine = SuperLoopingEngine(tokens: 4_200)
        let events = try await serve(engine, setting: .off)
        #expect(engine.cancelCount == 0)
        #expect(await events.stopReason == "length")
    }
}
