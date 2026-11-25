import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// The slot state the wedge monitor reports through a real bridge. A two-Mac
/// pair's engine reports no steps and its ranks prefill one prompt at a time,
/// so three long prompts behind one another are not a wedge; a single-Mac
/// engine whose steps stop while three requests wait for a first token is.
/// Each check reads the slot at an instant past the 10 s stall threshold. It
/// passes that instant as `now:`, as the heartbeat does, so no check sleeps.
@Suite("Wedge slot state", .timeLimit(.minutes(1)))
struct WedgeSlotStateTests {
    private static let pastStall: Duration = .milliseconds(Int(WedgeMonitor.suspectStallSeconds * 1000) + 1000)

    @Test("a pair's three prompts without a first token for 11 s do not read as crashed")
    func pairLongPrefillsAreNotAWedge() async throws {
        let owner = DistributedTestOwner()
        owner.lanes = 8
        let bridge = try DistributedEngineFactory.makeBridge(
            owner: owner, expectedIdentity: owner.identity, profile: distributedTestProfile(),
            tokenizer: TokenizerHandle(DistributedTestTokenizer()), eosTokenIDs: [99])
        var streams: [AsyncStream<GenerationEvent>] = []
        for id in ["a", "b", "c"] {
            streams.append(await bridge.submitTokenized(
                promptTokens: [1, 2, 3],
                request: ChatCompletionRequest(model: owner.identity.modelID, messages: [], temperature: 0, max_tokens: 1),
                requestId: id, cacheEnabled: false))
        }
        #expect(owner.reserveCount == 3)
        // One heartbeat sample now, and one at an instant past the stall threshold.
        #expect(await bridge.backendSlotCapacity().state == "running")
        let later = ContinuousClock.now.advanced(by: Self.pastStall)
        #expect(await bridge.backendSlotCapacity(now: later).state == "running", "a pair's long prefills read as a wedge")
        #expect(await bridge.wedgeMonitor.wedgeSuspected(now: later), "the wedge-suspected telemetry still reports the streak")
        for index in 0..<owner.reserveCount { owner.lease(index).acknowledge() }
        for stream in streams { for await _ in stream {} }
        await bridge.shutdown()
    }

    @Test("a pair request without a coordinator budget is tracked by the allowance its engine arms")
    func pairRequestWithoutABudgetIsTracked() async throws {
        let owner = DistributedTestOwner()
        let bridge = try DistributedEngineFactory.makeBridge(
            owner: owner, expectedIdentity: owner.identity, profile: distributedTestProfile(),
            tokenizer: TokenizerHandle(DistributedTestTokenizer()), eosTokenIDs: [99])
        let before = ContinuousClock.now
        let stream = await bridge.submitTokenized(
            promptTokens: [1, 2, 3],
            request: ChatCompletionRequest(model: owner.identity.modelID, messages: [], temperature: 0, max_tokens: 1),
            requestId: "unbudgeted", cacheEnabled: false)
        #expect(owner.reserveCount == 1)
        let allowance = try #require(await bridge.wedgeMonitor.firstTokenAllowance(for: "unbudgeted"))
        #expect(allowance > before)
        owner.last.send(.token(4))
        owner.last.acknowledge()
        for await _ in stream {}
        #expect(await bridge.wedgeMonitor.firstTokenAllowance(for: "unbudgeted") == nil, "its first token clears it")
        await bridge.shutdown()
    }

    @Test("a single-Mac engine whose steps stop under three waiting requests still reads as crashed")
    func singleMacWedgeIsStillCaught() async throws {
        let engine = PrefillScriptEngine()
        let bridge = EngineV2Bridge(
            engine: engine, modelId: "gpt-oss-20b",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [],
            maxConcurrentRequests: 4)
        var streams: [AsyncStream<GenerationEvent>] = []
        for id in ["a", "b", "c"] {
            streams.append(await bridge.submitTokenized(
                promptTokens: Array(repeating: 7, count: 16),
                request: ChatCompletionRequest(model: "gpt-oss-20b", messages: [], temperature: 0, max_tokens: 1),
                requestId: id, cacheEnabled: false))
        }
        #expect(engine.ordinarySubmissionCount == 3)
        #expect(await bridge.backendSlotCapacity().state != "crashed")
        let later = ContinuousClock.now.advanced(by: Self.pastStall)
        #expect(await bridge.backendSlotCapacity(now: later).state == "crashed")
        for continuation in engine.continuations {
            continuation.yield(.finished(reason: .cancelled, usage: CBv2Usage(promptTokens: 0, completionTokens: 0)))
            continuation.finish()
        }
        for stream in streams { for await _ in stream {} }
        await bridge.shutdown()
    }
}
