// Copyright © 2026 Eigen Labs.
// Turn continuation on a bridge: the hidden request runs on a real engine, the
// follow-up restores what it kept, and it never stands in front of a request.

import Foundation
import MLX
import MLXLLM
import Testing

@testable import MLXLMCommon
@testable import ProviderCore

@Suite("Turn continuation on a bridge", .serialized)
struct TurnContinuationBridgeTests {
    init() { _ = LiveInferenceFixtures.ensureMetallibColocated() }

    @Test("a build derives the cells from its grid and bank, and the key gates them")
    func theKeyGatesTheCells() async throws {
        let cells = TurnContinuationCells(gridTokens: 128, boundaryRule: nil, residentBank: true)
        let on = try ContinuationFixture.build()
        #expect(on.turnContinuationCells == cells)
        let enabled = try ContinuationFixture.factoryBridge(
            on, environment: [EngineV2Factory.turnContinuationKey: "1"])
        #expect(enabled.turnContinuationCells == cells)
        await enabled.shutdown()

        let off = try ContinuationFixture.build()
        let disabled = try ContinuationFixture.factoryBridge(off, environment: [:])
        #expect(disabled.turnContinuationCells == nil)
        await disabled.shutdown()

        // Without the grid no position is canonical, so there is nothing to cut at.
        let plain = try ContinuationFixture.build(grid: nil)
        #expect(plain.turnContinuationCells == nil)
        let ungridded = try ContinuationFixture.factoryBridge(
            plain, environment: [EngineV2Factory.turnContinuationKey: "1"])
        #expect(ungridded.turnContinuationCells == nil)
        await ungridded.shutdown()
    }

    /// One engine, two cache scopes that run the same turns: one continues
    /// after its first turn and one does not.
    @Test("a continuation prefills the next canonical position and the follow-up restores it")
    func theFollowUpRestoresWhatTheContinuationKept() async throws {
        let fixture = try ContinuationFixture()
        let bridge = fixture.bridge
        let source = ContinuationFixture.tokens(200)
        let shared = ContinuationFixture.tokens(300)
        let next = ContinuationFixture.tokens(340)

        for (id, scope) in [("a-1", "tenant-a"), ("b-1", "tenant-b")] {
            let reply = await fixture.run(id, prompt: source, scope: scope)
            #expect(!reply.failed && reply.completionTokens == 4, "\(reply)")
            try await fixture.settle()
        }
        // Each first turn left its one grid position, 128.
        #expect(await fixture.eventually { fixture.bank.stats.entries == 2 }, "\(fixture.bank.stats)")
        let first = fixture.bank.stats
        let work = await bridge.servingCountersTest()
        let admits = await bridge._testCounters().admits

        await bridge.continueTurn(after: "a-1", source: source, shared: shared, cacheScope: "tenant-a")
        await bridge.awaitTurnContinuationTest()
        try await fixture.settle()
        // One hidden request. It resumed at 128, and it is no one's served work.
        #expect(await bridge._testCounters().admits == admits + 1)
        #expect(await bridge.servingCountersTest() == work)
        #expect(await bridge.turnContinuationIdleTest())
        #expect(await fixture.eventually { fixture.bank.stats.checkpoints > first.checkpoints },
            "\(fixture.bank.stats)")
        let continued = fixture.bank.stats
        #expect(continued.tokensSaved - first.tokensSaved == 128, "\(continued)")

        // The continued scope restores 256, the position the hidden request
        // reached; the other restores its first turn's 128.
        let followed = await fixture.run("a-2", prompt: next, scope: "tenant-a")
        try await fixture.settle()
        let afterFollowed = fixture.bank.stats
        #expect(afterFollowed.tokensSaved - continued.tokensSaved == 256, "\(afterFollowed)")
        let control = await fixture.run("b-2", prompt: next, scope: "tenant-b")
        try await fixture.settle()
        let afterControl = fixture.bank.stats
        #expect(afterControl.tokensSaved - afterFollowed.tokensSaved == 128, "\(afterControl)")
        #expect(!followed.failed && !followed.text.isEmpty && followed == control,
            "\(followed) against \(control)")
        await bridge.shutdown()
    }

    @Test("a continuation is skipped, not queued, while a request holds the Mac or nothing is new")
    func aContinuationIsSkippedNotQueued() async throws {
        let fixture = try ContinuationFixture()
        let bridge = fixture.bridge
        let source = ContinuationFixture.tokens(200)
        let reply = await fixture.run("a-1", prompt: source, scope: "tenant-a")
        #expect(!reply.failed, "\(reply)")
        try await fixture.settle()
        let admits = await bridge._testCounters().admits

        // Every request on this Mac holds a foreground lease while it is served.
        let lease = try #require(await fixture.budget.serviceBudget.idleCalibration.admittedLease())
        await bridge.continueTurn(
            after: "a-1", source: source, shared: ContinuationFixture.tokens(300), cacheScope: "tenant-a")
        #expect(!(await bridge.turnContinuationScheduledTest()))
        lease.finish()
        #expect(!(await bridge.turnContinuationScheduledTest()))
        #expect(!fixture.budget.serviceBudget.idleCalibration.hasSession)

        // The first turn already left the last canonical position of this prefix.
        await bridge.continueTurn(
            after: "a-1", source: source, shared: ContinuationFixture.tokens(220), cacheScope: "tenant-a")
        #expect(!(await bridge.turnContinuationScheduledTest()))
        #expect(await bridge._testCounters().admits == admits)
        await bridge.shutdown()
    }

    /// Where the arrival finds the hidden request is pinned as far as a test
    /// can pin it: right after it is scheduled, or once the engine holds it.
    /// What holds wherever it lands is asserted.
    @Test("an arriving request ends a continuation and is served as if none had run",
        arguments: [false, true])
    func anArrivalEndsAContinuation(onceTheEngineHoldsIt: Bool) async throws {
        let fixture = try ContinuationFixture()
        let bridge = fixture.bridge
        let source = ContinuationFixture.tokens(200)
        let shared = ContinuationFixture.tokens(1_900)
        let next = ContinuationFixture.tokens(1_940)

        // The same two turns with no continuation between them, and the second
        // turn alone in a scope that holds nothing.
        var plain = ContinuationFixture.Reply()
        for (id, prompt) in [("b-1", source), ("b-2", next)] {
            plain = await fixture.run(id, prompt: prompt, scope: "tenant-b")
            #expect(!plain.failed && plain.completionTokens == 4, "\(plain)")
            try await fixture.settle()
        }
        let cold = await fixture.run("c-1", prompt: next, scope: "tenant-c")
        try await fixture.settle()
        let opened = await fixture.run("a-1", prompt: source, scope: "tenant-a")
        #expect(!opened.failed, "\(opened)")
        try await fixture.settle()
        let work = await bridge.servingCountersTest()
        let admits = await bridge._testCounters().admits

        await bridge.continueTurn(after: "a-1", source: source, shared: shared, cacheScope: "tenant-a")
        if onceTheEngineHoldsIt {
            let deadline = ContinuousClock.now + .seconds(5)
            while await bridge._testCounters().admits == admits {
                try #require(ContinuousClock.now < deadline, "the engine never took the continuation")
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        let arrived = await fixture.run("a-2", prompt: next, scope: "tenant-a")
        await bridge.awaitTurnContinuationTest()
        try await fixture.settle()

        #expect(!arrived.failed && !arrived.text.isEmpty && arrived == plain && arrived == cold,
            "\(arrived) against \(plain) and \(cold)")
        #expect(await bridge.turnContinuationIdleTest())
        #expect(!fixture.budget.serviceBudget.idleCalibration.hasSession)
        // Generated tokens and generation requests: the arrival's alone.
        let after = await bridge.servingCountersTest()
        #expect(after[2] - work[2] == 4 && after[3] - work[3] == 1, "\(work) then \(after)")
        if onceTheEngineHoldsIt {
            #expect(await bridge._testCounters().admits == admits + 2)
        }
        await bridge.shutdown()
    }
}

/// A two-layer hybrid model, one recurrent layer and one attention layer, on a
/// 128-token canonical grid with a resident bank.
private struct ContinuationFixture {
    static let modelID = "turn-continuation-fixture"
    let engine: EngineV2
    let bank: CBv2HybridPrefixCache
    let budget: GlobalKVCacheBudget
    let bridge: EngineV2Bridge

    struct Reply: Equatable {
        var text = ""
        var completionTokens: Int?
        var finishReason: String?
        var failed = false
    }

    init() throws {
        let build = try Self.build()
        engine = try #require(build.engine as? EngineV2)
        bank = try #require(engine.hybridPrefixCache)
        budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
        }
        // Built directly: the factory leaves the posture gate on the host's
        // thermal state, which a test cannot hold still.
        bridge = EngineV2Bridge(
            engine: build.engine, modelId: Self.modelID,
            tokenizer: TokenizerHandle(ContinuationTokenizer()), eosTokenIds: [],
            maxConcurrentRequests: 2, kvBytesPerToken: 256, kvBudget: budget,
            kvBackendKind: build.kvBackendKind,
            calibrationPosturePermitsWork: { true },
            turnContinuationCells: build.turnContinuationCells,
            emitTelemetry: { _ in })
    }

    /// The bank is built on contiguous storage here because that is where the
    /// engine builds one without an opt-in; it is this fixture's choice only.
    static func build(grid: String? = "128") throws -> EngineV2Factory.ProductionBuild {
        var environment = [
            KVBackendGuardStore.pathEnvKey: "/dev/null",
            EngineV2KVQuantizationPolicy.environmentKey: "native",
        ]
        environment[EngineV2Factory.canonicalPrefillGridKey] = grid
        return try EngineV2Factory.makeProductionBuild(
            model: try makeModel(), modelID: modelID, tokenizer: ContinuationTokenizer(),
            kvBytesCapacity: 4 << 30, maxConcurrentRequests: 2,
            hybridPrefixCache: CBv2HybridPrefixCacheConfig(
                maximumBytes: 256 << 20, modelID: modelID,
                promptContractID: "fixture-contract", buildID: "fixture-build"),
            mtpConfig: .init(enabled: false), kvBackend: .contiguous, maxContextLength: 2_048,
            environment: environment)
    }

    static func factoryBridge(
        _ build: EngineV2Factory.ProductionBuild, environment: [String: String]
    ) throws -> EngineV2Bridge {
        try EngineV2Factory.makeBridge(
            modelId: modelID, tokenizer: TokenizerHandle(ContinuationTokenizer()), eosTokenIds: [],
            maxConcurrentRequests: 2, runtimePolicyEnvironment: environment, kvBytesPerToken: 256,
            emitTelemetry: { _ in }, makeEngine: { build })
    }

    /// The first `count` tokens of one fixed conversation.
    static func tokens(_ count: Int) -> [Int] {
        (0 ..< count).map { ($0 * 7 + 3) % 61 + 1 + ($0 / 61) % 2 }
    }

    func run(_ id: String, prompt: [Int], scope: String) async -> Reply {
        let stream = await bridge.submitTokenized(
            promptTokens: prompt,
            request: ChatCompletionRequest(
                model: Self.modelID, messages: [], temperature: 0, max_tokens: 4),
            requestId: id, cacheScope: scope)
        var reply = Reply()
        for await event in stream {
            switch event {
            case .logprobs: break
            case .chunk(let text): reply.text += text
            case .info(_, let completion, _, let finishReason):
                reply.completionTokens = completion
                reply.finishReason = finishReason
            case .error, .terminal: reply.failed = true
            }
        }
        return reply
    }

    /// The engine republishes its gauges at the step after the terminal the
    /// bridge retires on, so a finished request can still count for a moment.
    func settle() async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            let active = engine.capacity().activeRequests
            let charges = budget.serviceBudget.count
            if active == 0 && charges == 0 { return }
            try #require(ContinuousClock.now < deadline,
                "the engine never retired its requests: active=\(active), service charges=\(charges)")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The bank publishes after a request retires. Polls for up to five seconds.
    func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private static func makeModel() throws -> Qwen35Model {
        let json = """
        {"model_type":"qwen3_5","hidden_size":64,"num_hidden_layers":2,
         "intermediate_size":128,"num_attention_heads":1,"num_key_value_heads":1,
         "head_dim":64,"linear_num_value_heads":1,"linear_num_key_heads":1,
         "linear_key_head_dim":64,"linear_value_head_dim":64,"linear_conv_kernel_dim":4,
         "vocab_size":64,"full_attention_interval":2,"num_experts":0,"num_experts_per_tok":0,
         "mtp_num_hidden_layers":0}
        """
        return Qwen35Model(try EngineV2VLMTextExtraction.decodeQwenConfiguration(configData: Data(json.utf8)))
    }
}

/// Decodes each token to its own word, so two replies are equal only when
/// their tokens are.
private struct ContinuationTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.map { "t\($0) " }.joined()
    }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [] }
}

private extension EngineV2Bridge {
    func awaitTurnContinuationTest() async { await modelCalibration.task?.value }
    func turnContinuationScheduledTest() -> Bool { modelCalibration.task != nil }
    func turnContinuationIdleTest() -> Bool {
        modelCalibration.task == nil && modelCalibration.requests.isEmpty && active.isEmpty
    }
    /// Prefill tokens, prefill requests, generated tokens, generation requests.
    func servingCountersTest() -> [Int64] {
        [prefillTokensTotal, prefillRequestsTotal, generatedTokensTotal, generationRequestsTotal]
    }
}
