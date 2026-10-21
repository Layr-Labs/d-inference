// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Testing
@testable import ProviderCore

private actor SuperPrefillRun {
    var text = ""
    var errors: [String] = []
    func record(_ event: GenerationEvent) {
        switch event {
        case .chunk(let chunk): text += chunk
        case .info: break
        case .error(let message): errors.append(message)
        case .terminal(_, let message, _, _): errors.append(message)
        }
    }
}

/// The Super owner's prompt policy and its single prefill lane: canonical
/// chunks whatever the concurrency, one chunk per step, decode rows between
/// chunks, and one activation charge per owner rather than per request.
struct NemotronSuperLocalPrefillTests {
    typealias Prefill = NemotronSuperLocalPrefill
    typealias Builder = NemotronSuperLocalBridgeBuilder

    @Test func policyIsExplicitBoundedAndKeepsChunksWhole() throws {
        #expect(try Prefill.Policy.resolve(environment: [:], prefillLimit: 4096)
            == .init(chunkTokens: 2048, decodeStepsBetweenChunks: 0))
        #expect(try Prefill.Policy.resolve(environment: [:], prefillLimit: 512).chunkTokens == 512)
        #expect(try Prefill.Policy.resolve(
            environment: [Prefill.chunkKey: " 1024 ", Prefill.decodeStepsKey: "3"], prefillLimit: 4096)
            == .init(chunkTokens: 1024, decodeStepsBetweenChunks: 3))
        for value in ["0", "4097", "-1", "two", ""] {
            #expect(throws: Prefill.Failure.invalidChunk) {
                try Prefill.Policy.resolve(environment: [Prefill.chunkKey: value], prefillLimit: 4096)
            }
        }
        for value in ["-1", "65", "x"] {
            #expect(throws: Prefill.Failure.invalidDecodeSteps) {
                try Prefill.Policy.resolve(environment: [Prefill.decodeStepsKey: value], prefillLimit: 4096)
            }
        }
        var config = CBv2SchedulerConfig(maxConcurrentRequests: 4, maxBatchedTokensPerStep: 100,
            prefillChunkSize: 512, soloPrefillStripeTokens: 4096, mixedStepPrefillTokenCap: 64)
        Prefill.Policy(chunkTokens: 2048, decodeStepsBetweenChunks: 2)
            .apply(to: &config, requests: 4, draftTokens: 3)
        #expect(config.prefillChunkSize == 2048 && config.maxBatchedTokensPerStep == 2048 + 4 * 4)
        #expect(config.soloPrefillStripeTokens == nil && config.mixedStepPrefillTokenCap == 2048)
        #expect(config.maxPrefillRowsPerStep == 1 && config.maxConcurrentPartialPrefills == 1)
        #expect(config.decodeStepsBetweenPrefillChunks == 2)
    }

    @Test func pinnedCheckpointLaneChargesTheMeasuredWholeChunkBound() throws {
        let fixture = try SuperMTPInstalledFixture().make()
        let language = try #require(fixture.installed.model?.languageModel)
        let workspace = try #require(language.modelOptGraphPrefillWorkspaceBytes(tokens: 2048))
        #expect(Prefill.laneBytes(language, chunkTokens: 2048, measuredBound: false) == workspace)
        #expect(Prefill.laneBytes(language, chunkTokens: 2048, measuredBound: true)
            == max(workspace, NemotronHModel.prefillActivationBoundBytes(tokens: 2048)))
        #expect(NemotronHModel.prefillActivationBoundBytes(tokens: 2048) == (1 << 30) + 2048 * (15 << 18))
        let id = Prefill.laneReservationID()
        #expect(Prefill.isLaneReservationID(id) && !Prefill.isLaneReservationID("decode-contended-prefill"))
        // A synthetic installation is never the pinned checkpoint.
        #expect(!fixture.installed.isPinnedCheckpoint)
        fixture.installed.closeAfterRetirement()
    }

    private static func owner(_ fixture: SuperMTPInstalledFixture.Installation,
                              setting: NemotronSuperLocalMTP.Setting?, environment: [String: String],
                              budget: GlobalKVCacheBudget, lease: PendingModelLoadLease)
        async throws -> Builder.Owner {
        try await Builder.make(installed: fixture.installed,
            tokenizer: TokenizerHandle(SuperTokenTextTokenizer()), eosTokenIDs: [63],
            sizing: .init(weightsBytes: fixture.installed.receipt.payloadBytes,
                fp16KVBytesPerToken: 64, maxContextLength: 64, defaultMaxTokens: 16),
            kvBytesCapacity: 4 << 30, kvBudget: budget, loadLease: lease,
            construction: fixture.construction,
            mtp: setting.map { .init(module: fixture.head, setting: $0) },
            environment: environment)
    }

    private static func run(_ owner: Builder.Owner, prompt: [Int], maxTokens: Int)
        async throws -> (text: String, errors: [String]) {
        let events = SuperPrefillRun()
        try await owner.localTextBinding().run(request: .init(model: NemotronSuperLocalBinding.modelID,
            messages: [], temperature: 0, max_tokens: maxTokens), promptTokens: prompt) {
            await events.record($0)
        }
        return (await events.text, await events.errors)
    }

    private static let requests: [(prompt: [Int], maxTokens: Int)] = [
        ((0 ..< 21).map { (i: Int) -> Int in (i * 7 + 3) % 61 + 1 }.filter { $0 != 18 }, 12), ([5, 9, 1, 4, 22, 7, 3, 8, 30], 10),
        ([40, 2, 9], 14),
    ]

    private static func budget() -> GlobalKVCacheBudget {
        GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: .max) })
    }

    /// A burst through a plain batched owner and a speculative batched owner,
    /// prompts of several 4-token chunks, decode-only steps between chunks:
    /// each text equals the plain owner serving that request alone with the
    /// same chunk. Each owner holds exactly one lane while it lives.
    @Test(.timeLimit(.minutes(3)), arguments: [(false, 0), (false, 1), (true, 0), (true, 2)])
    func burstMatchesSoloServingAndHoldsOneLane(speculative: Bool, decodeSteps: Int) async throws {
        let budget = Self.budget()
        let soloFixture = try SuperMTPInstalledFixture().make()
        let fixture = try SuperMTPInstalledFixture().make()
        var leases: [PendingModelLoadLease] = []
        for (name, installation) in [("solo", soloFixture), ("burst", fixture)] {
            let bytes = installation.installed.receipt.payloadBytes
                + (try NemotronSuperLocalMTP.loadSupplementBytes(installation.headQuote))
            leases.append(try #require(await budget.claimPendingLoad(
                requestID: "super-prefill-\(name)", weightBytes: UInt64(bytes), minimumKVBytes: 4 << 30)))
        }
        let chunk = [Prefill.chunkKey: "4"]
        let solo = try await Self.owner(soloFixture, setting: nil, environment: chunk, budget: budget,
            lease: leases[0])
        var expected: [String] = []
        for request in Self.requests {
            let result = try await Self.run(solo, prompt: request.prompt, maxTokens: request.maxTokens)
            #expect(result.errors.isEmpty, "\(result.errors)")
            expected.append(result.text)
        }
        try await solo.closeAfterDrain()
        let environment = chunk.merging([Builder.maxConcurrentKey: "3",
            Prefill.decodeStepsKey: "\(decodeSteps)"]) { $1 }
        let owner = try await Self.owner(fixture, setting: speculative ? .init(depth: 2) : nil,
            environment: environment, budget: budget, lease: leases[1])
        #expect(owner.prefill == .init(chunkTokens: 4, decodeStepsBetweenChunks: decodeSteps))
        let lanes = await budget.reservationBytesSnapshot().filter { Prefill.isLaneReservationID($0.key) }
        #expect(lanes.count == 1 && lanes.first?.value == UInt64(owner.prefillLaneBytes))
        let actual = try await withThrowingTaskGroup(of: (Int, (text: String, errors: [String])).self) {
            group in
            for (index, request) in Self.requests.enumerated() {
                group.addTask {
                    (index, try await Self.run(owner, prompt: request.prompt, maxTokens: request.maxTokens))
                }
            }
            var results: [Int: (text: String, errors: [String])] = [:]
            for try await (index, result) in group { results[index] = result }
            return results
        }
        for index in Self.requests.indices {
            let result = try #require(actual[index])
            #expect(result.errors.isEmpty, "\(result.errors)")
            #expect(result.text == expected[index],
                "request \(index) speculative \(speculative) decode steps \(decodeSteps)")
        }
        try await owner.closeAfterDrain()
        #expect(await budget.reservationBytesSnapshot().isEmpty)
        for lease in leases { #expect(await budget.finishPendingLoad(lease)) }
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    /// A lane that does not fit the shared budget fails the load before any
    /// request is admitted, and nothing stays charged.
    @Test(.timeLimit(.minutes(2))) func laneThatDoesNotFitFailsTheLoad() async throws {
        let fixture = try SuperMTPInstalledFixture().make()
        let language = try #require(fixture.installed.model?.languageModel)
        let lane = Prefill.laneBytes(language,
            chunkTokens: min(Prefill.defaultChunkTokens, try #require(language.calibratedPrefillTokenLimit)),
            measuredBound: false)
        let budget = Self.budget()
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-prefill-small",
            weightBytes: UInt64(fixture.installed.receipt.payloadBytes), minimumKVBytes: 2 << 30))
        // Ballast leaves about half the lane free: the largest reservation that
        // still fits, found by bisection, minus half the lane.
        var low: UInt64 = 0
        var high: UInt64 = 64 << 30
        while low < high {
            let middle = low + (high - low + 1) / 2
            if await budget.reserveBytes(requestID: "probe", bytes: middle) {
                await budget.release(requestID: "probe")
                low = middle
            } else {
                high = middle - 1
            }
        }
        #expect(low > UInt64(lane))
        #expect(await budget.reserveBytes(requestID: "ballast", bytes: low - UInt64(lane / 2)))
        await #expect(throws: Prefill.Failure.laneRefused) {
            _ = try await Builder.make(installed: fixture.installed,
                tokenizer: TokenizerHandle(SuperTokenTextTokenizer()), eosTokenIDs: [63],
                sizing: .init(weightsBytes: fixture.installed.receipt.payloadBytes,
                    fp16KVBytesPerToken: 64, maxContextLength: 64, defaultMaxTokens: 16),
                kvBytesCapacity: 2 << 30, kvBudget: budget,
                loadLease: lease, construction: fixture.construction, environment: [:])
        }
        #expect(await budget.reservationBytesSnapshot().keys.sorted() == ["ballast"])
        await budget.release(requestID: "ballast")
        fixture.installed.closeAfterRetirement()
        #expect(await budget.finishPendingLoad(lease))
    }
}
