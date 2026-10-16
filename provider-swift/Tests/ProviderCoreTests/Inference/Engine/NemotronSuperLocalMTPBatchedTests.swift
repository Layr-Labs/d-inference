// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import Testing
@testable import ProviderCore

private actor SuperMTPBatchedRun {
    var text = ""
    var completions: [Int] = []
    var errors: [String] = []
    func record(_ event: GenerationEvent) {
        switch event {
        case .chunk(let chunk): text += chunk
        case .info(_, let completion, _, _): completions.append(completion)
        case .error(let message): errors.append(message)
        case .terminal(_, let message, _, _): errors.append(message)
        }
    }
}

/// The speculative owner serving several concurrent requests: one captured
/// verify window per round across requests, each committing its own accepted
/// prefix. Every request's text must equal the plain owner serving it alone.
/// Synthetic fixture weights; nothing here is model speed evidence.
struct NemotronSuperLocalMTPBatchedTests {
    typealias Builder = NemotronSuperLocalBridgeBuilder

    private static let budgetSnapshot: @Sendable () -> GlobalKVCacheBudget.MemorySnapshot = {
        .init(total: 32 << 30, active: 0, cache: 0, systemAvailable: .max)
    }

    private static func owner(_ fixture: SuperMTPInstalledFixture.Installation,
                              setting: NemotronSuperLocalMTP.Setting?, requests: Int,
                              grant: Int = 4 << 30, budget: GlobalKVCacheBudget,
                              lease: PendingModelLoadLease) async throws -> Builder.Owner {
        try await Builder.make(installed: fixture.installed,
            tokenizer: TokenizerHandle(SuperTokenTextTokenizer()), eosTokenIDs: [63],
            sizing: .init(weightsBytes: fixture.installed.receipt.payloadBytes,
                fp16KVBytesPerToken: 64, maxContextLength: 64, defaultMaxTokens: 16),
            kvBytesCapacity: grant, kvBudget: budget, loadLease: lease,
            construction: fixture.construction,
            mtp: setting.map { .init(module: fixture.head, setting: $0) },
            environment: [Builder.maxConcurrentKey: "\(requests)"])
    }

    private static func run(_ owner: Builder.Owner, prompt: [Int], maxTokens: Int)
        async throws -> (text: String, completions: [Int], errors: [String]) {
        let binding = try owner.localTextBinding()
        let events = SuperMTPBatchedRun()
        try await binding.run(request: .init(model: NemotronSuperLocalBinding.modelID,
            messages: [], temperature: 0, max_tokens: maxTokens), promptTokens: prompt) {
            await events.record($0)
        }
        return (await events.text, await events.completions, await events.errors)
    }

    private static let requests: [(prompt: [Int], maxTokens: Int)] = [
        ([5, 9, 1, 4, 22, 7, 3, 8, 30], 14), ([1, 2, 3], 9), ([40], 12),
        ((0 ..< 20).map { (i: Int) -> Int in (i * 7 + 3) % 61 + 1 }.filter { $0 != 18 }, 16),
    ]

    @Test(.timeLimit(.minutes(3)), arguments: [(1, 3, false), (3, 3, false), (2, 4, false), (3, 4, true)])
    func speculativeOwnerServesConcurrentRequestsExactly(depth: Int, rows: Int, adaptive: Bool)
        async throws {
        let plainFixture = try SuperMTPInstalledFixture().make()
        let speculativeFixture = try SuperMTPInstalledFixture().make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: Self.budgetSnapshot)
        var leases: [PendingModelLoadLease] = []
        for (name, fixture) in [("plain", plainFixture), ("speculative", speculativeFixture)] {
            let bytes = fixture.installed.receipt.payloadBytes
                + (try NemotronSuperLocalMTP.loadSupplementBytes(fixture.headQuote))
            leases.append(try #require(await budget.claimPendingLoad(
                requestID: "super-mtp-batched-\(name)", weightBytes: UInt64(bytes),
                minimumKVBytes: 4 << 30)))
        }
        let plain = try await Self.owner(plainFixture, setting: nil, requests: 1, budget: budget,
            lease: leases[0])
        let speculative = try await Self.owner(speculativeFixture,
            setting: .init(depth: depth, adaptive: adaptive), requests: rows, budget: budget,
            lease: leases[1])
        #expect(speculative.speculates && speculative.maximumLocalRequests == rows)
        #expect(await speculative.bridge.effectiveServingConcurrency == rows)
        var expected: [(text: String, completions: [Int], errors: [String])] = []
        for request in Self.requests {
            expected.append(try await Self.run(plain, prompt: request.prompt, maxTokens: request.maxTokens))
        }
        // The bridge refuses a request beyond its width, so submit at most
        // `rows` at once.
        var actual: [Int: (text: String, completions: [Int], errors: [String])] = [:]
        for start in stride(from: 0, to: Self.requests.count, by: rows) {
            let cohort = Array(start ..< min(start + rows, Self.requests.count))
            try await withThrowingTaskGroup(
                of: (Int, (text: String, completions: [Int], errors: [String])).self
            ) { group in
                for index in cohort {
                    let request = Self.requests[index]
                    group.addTask {
                        (index, try await Self.run(speculative, prompt: request.prompt,
                            maxTokens: request.maxTokens))
                    }
                }
                for try await (index, result) in group { actual[index] = result }
            }
        }
        for index in Self.requests.indices {
            let result = try #require(actual[index])
            #expect(expected[index].errors.isEmpty && result.errors.isEmpty, "\(result.errors)")
            #expect(result.text == expected[index].text,
                "request \(index) depth \(depth) rows \(rows) adaptive \(adaptive)")
            #expect(result.completions == expected[index].completions)
        }
        let ownedEngine = await speculative.bridge.ownedEngine
        let engine = try #require(ownedEngine as? EngineV2)
        let metrics = try #require(engine.mtpMetricsSnapshot())
        #expect(metrics.serialVerificationRounds == 0)
        // The adaptive policy may settle on target-only steps for this fixture.
        if !adaptive { #expect(metrics.rounds > 0 && metrics.rectangularVerificationRounds > 0) }
        print("SYNTHETIC provider super-mtp-batched depth=\(depth) rows=\(rows) "
            + "verifySteps=\(metrics.rectangularVerificationRounds) rounds=\(metrics.rounds) "
            + "drafted=\(metrics.draftedTokens) accepted=\(metrics.acceptedTokens)")
        try await plain.closeAfterDrain()
        try await speculative.closeAfterDrain()
        #expect(plainFixture.residency.snapshot.usedBytes == 0)
        #expect(speculativeFixture.residency.snapshot.usedBytes == 0)
        for lease in leases { #expect(await budget.finishPendingLoad(lease)) }
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    /// Every concurrent request carries the assistant's bounded charge, so the
    /// grant must hold all of them; serial verification keeps one request.
    @Test(.timeLimit(.minutes(2))) func speculativeOwnerNeedsAGrantForEveryRequest() async throws {
        let grant = Int(UnifiedMemoryCap.minimumLoadKVBytes)
        var refusals: [Int: Builder.UnserviceableGrant] = [:]
        for rows in [1, 3] {
            let fixture = try SuperMTPInstalledFixture().make()
            let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
                memorySnapshot: Self.budgetSnapshot)
            let bytes = fixture.installed.receipt.payloadBytes
                + (try NemotronSuperLocalMTP.loadSupplementBytes(fixture.headQuote))
            let lease = try #require(await budget.claimPendingLoad(requestID: "super-mtp-rows-\(rows)",
                weightBytes: UInt64(bytes), minimumKVBytes: UInt64(grant)))
            do {
                _ = try await Self.owner(fixture, setting: .init(depth: 2), requests: rows,
                    grant: grant, budget: budget, lease: lease)
                Issue.record("a minimum-KV grant served \(rows) speculative requests")
            } catch let refusal as Builder.UnserviceableGrant {
                refusals[rows] = refusal
            }
            fixture.installed.closeAfterRetirement()
            #expect(await budget.finishPendingLoad(lease))
        }
        let (one, three) = (try #require(refusals[1]), try #require(refusals[3]))
        #expect(three.requests == 3 && three.fixedRequestBytes == one.fixedRequestBytes)
        #expect(three.minimumGrantBytes >= one.minimumGrantBytes + 2 * one.fixedRequestBytes)

        let fixture = try SuperMTPInstalledFixture().make()
        #expect(throws: Builder.Failure.invalidConcurrency) {
            try NemotronSuperLocalMTP.engine(for: try #require(fixture.installed.model),
                head: .init(module: fixture.head, setting: .init(depth: 1, verification: .serial)),
                maximumSequenceLength: 64, requests: 2)
        }
        fixture.installed.closeAfterRetirement()
    }
}
