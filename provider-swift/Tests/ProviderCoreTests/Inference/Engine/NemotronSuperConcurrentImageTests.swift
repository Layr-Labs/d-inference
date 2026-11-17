import Foundation
import MLX
@testable import MLXLMCommon
@testable import MLXVLM
import Testing
@testable import ProviderCore

/// Real synthetic vision preparation, provider admission and native decode.
/// The scheduler gate delays work, never fabricates tokens or native completion.
@Suite(.serialized)
struct NemotronSuperConcurrentImageTests {
    @Test(.timeLimit(.minutes(2)))
    func imagesEncodeSeriallyAndDecodeTogetherBeforeEitherRetires() async throws {
        let fixture = try SuperMTPInstalledFixture().make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 16 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-concurrent-images",
            weightBytes: UInt64(fixture.installed.receipt.payloadBytes), minimumKVBytes: 4 << 30))
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: fixture.installed,
            tokenizer: TokenizerHandle(SuperSyntheticImageTokenizer()), eosTokenIDs: [],
            sizing: .init(weightsBytes: fixture.installed.receipt.payloadBytes,
                fp16KVBytesPerToken: 64, maxContextLength: 64, defaultMaxTokens: 16),
            kvBytesCapacity: 4 << 30, kvBudget: budget, loadLease: lease,
            construction: fixture.construction,
            environment: [NemotronSuperLocalBridgeBuilder.maxConcurrentKey: "4",
                          "DARKBLOOM_NEMOTRON_SUPER_CONCURRENT_IMAGES": "1"])
        let images = try owner.localImageBinding()
        let engine = try #require(await owner.bridge.ownedEngine as? EngineV2)
        let loop = engine.loopForTesting
        let preparation = SuperImagePreparationProbe()
        let terminals = SuperImageNativeTerminals()
        let firstEvents = ConcurrentImageEvents(), secondEvents = ConcurrentImageEvents()
        await images.setTestPreparation { id, entering in await preparation.observe(id, entering) }
        await owner.bridge._testInstallPersistentTerminalGate { usage in await terminals.record(usage) }
        loop.onEngineQueueSync { loop.suspendStepExecutionAtCountForTesting = 0 }
        let baseline = await budget.outstandingReservedBytes()
        let request = ChatCompletionRequest(model: owner.modelID, messages: [], temperature: 0, max_tokens: 16)
        let firstInput = NemotronSuperLocalImageBinding.Input(promptTokens: [1, 18, 2],
            normalizedImages: [MLXArray.zeros([1, 1, 4, 4])])
        let secondInput = NemotronSuperLocalImageBinding.Input(promptTokens: [3, 18, 4],
            normalizedImages: [MLXArray.ones([1, 1, 4, 4])])
        let firstQuote = try NemotronSuperLocalImageBinding.preparationQuote(firstInput, contextLength: 64)
        let secondQuote = try NemotronSuperLocalImageBinding.preparationQuote(secondInput, contextLength: 64)
        let first = Task {
            try await images.run(request: request, input: firstInput) { _ = await firstEvents.record($0) }
        }
        var second: Task<Void, Error>?
        do {
            try await superHTTPEventually("first image inside real preparation") {
                await preparation.started == 1
            }
            second = Task {
                try await images.run(request: request, input: secondInput) { _ = await secondEvents.record($0) }
            }
            // Force contention while the first encoder holds its lane.
            try await Task.sleep(for: .milliseconds(100))
            #expect(await preparation.started == 1)
            await preparation.releaseFirst()
            try await superHTTPEventually("both encoded images admitted before native completion") {
                let count = loop.onEngineQueueSync {
                    loop.scheduler.runningCount + loop.scheduler.waitingCount
                }
                return count == 2
            }
            #expect(await preparation.finished == 2)
            #expect(await preparation.maximumActive == 1)
            #expect(await terminals.count == 0)
            #expect(await firstEvents.completions.isEmpty)
            #expect(await secondEvents.completions.isEmpty)
            #expect(await budget.outstandingReservedBytes()
                >= baseline + firstQuote.totalBytes + secondQuote.totalBytes)

            loop.onEngineQueueSync { loop.suspendStepExecutionAtCountForTesting = nil }
            try await first.value
            try await second?.value
            #expect(await firstEvents.errors.isEmpty)
            #expect(await secondEvents.errors.isEmpty)
            #expect(await firstEvents.completions == [16])
            #expect(await secondEvents.completions == [16])
            #expect(await terminals.count == 2)
            #expect(await terminals.maximumBatchRows >= 2,
                    "Two host tasks are insufficient: a native step must produce tokens for both rows")
            #expect(await budget.outstandingReservedBytes() == baseline)
        } catch {
            await preparation.releaseFirst()
            loop.onEngineQueueSync { loop.suspendStepExecutionAtCountForTesting = nil }
            first.cancel(); second?.cancel()
            _ = await first.result
            _ = await second?.result
            try await owner.closeAfterDrain()
            _ = await budget.finishPendingLoad(lease)
            throw error
        }
        try await owner.closeAfterDrain()
        #expect(fixture.residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}

private actor SuperImagePreparationProbe {
    private var active = Set<String>()
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = 0
    private(set) var finished = 0
    private(set) var maximumActive = 0

    func observe(_ id: String, _ entering: Bool) async {
        if entering {
            started += 1
            active.insert(id)
            maximumActive = max(maximumActive, active.count)
            if started == 1 && !released {
                await withCheckedContinuation { continuation = $0 }
            }
        } else {
            active.remove(id)
            finished += 1
        }
    }

    func releaseFirst() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor SuperImageNativeTerminals {
    private(set) var count = 0
    private(set) var maximumBatchRows: UInt32 = 0
    func record(_ usage: CBv2Usage) {
        count += 1
        maximumBatchRows = max(maximumBatchRows, usage.timing.batchRowsMax)
    }
}

private actor ConcurrentImageEvents {
    private(set) var completions: [Int] = []
    private(set) var errors: [String] = []
    func record(_ event: GenerationEvent) {
        switch event {
        case .chunk, .logprobs: break
        case .info(_, let count, _, _): completions.append(count)
        case .error(let message), .terminal(_, let message, _, _): errors.append(message)
        }
    }
}
