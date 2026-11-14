// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
@testable import MLXLMCommon
import MLXVLM
import Testing
@testable import ProviderCore

@Suite(.serialized)
struct NemotronSuperConcurrentImageLifecycleTests {
    private typealias Binding = NemotronSuperLocalImageBinding

    @Test(.timeLimit(.minutes(2)))
    func encodedImagesBothEnterTheEngineBeforeEitherCompletes() async throws {
        let session = try await ConcurrentImageSession.make(encoded: true)
        let latch = ConcurrentImagePreparationLatch()
        await session.images.setTestPreparation { _, entering in await latch.observe(entering) }
        let engine = try #require(await session.owner.bridge.ownedEngine as? EngineV2)
        let loop = engine.loopForTesting
        loop.onEngineQueueSync { loop.suspendStepExecutionAtCountForTesting = 0 }
        let baseline = await session.budget.outstandingReservedBytes()
        let first = Task { try await session.run() }
        var second: Task<Void, Error>?
        do {
            try await superHTTPEventually("encoded first image holds preparation") { await latch.started == 1 }
            second = Task { try await session.run() }
            try await superHTTPEventually("both encoded image quotes charged") {
                await session.budget.outstandingReservedBytes() == baseline + 2 * session.quote
            }
            #expect(await latch.started == 1)
            await latch.release()
            try await superHTTPEventually("both encoded images reach the frozen native loop") {
                loop.onEngineQueueSync { loop.scheduler.runningCount + loop.scheduler.waitingCount == 2 }
            }
            #expect(await latch.started == 2)
            #expect(await session.budget.outstandingReservedBytes() >= baseline + 2 * session.quote)
            loop.onEngineQueueSync { loop.suspendStepExecutionAtCountForTesting = nil }
            try await first.value; try await second?.value
            #expect(await session.budget.outstandingReservedBytes() == baseline)
        } catch {
            first.cancel(); second?.cancel(); await latch.release()
            loop.onEngineQueueSync { loop.suspendStepExecutionAtCountForTesting = nil }
            _ = await first.result; _ = await second?.result
            try await session.close()
            throw error
        }
        try await session.close()
    }

    @Test(.timeLimit(.minutes(2)), arguments: [("", 4), ("0", 4), ("true", 4), ("1", 2)])
    func disabledOrNarrowOwnerKeepsSingleMediaAdmission(flag: String, width: Int) async throws {
        let session = try await ConcurrentImageSession.make(flag: flag, width: width)
        let latch = ConcurrentImagePreparationLatch()
        await session.images.setTestPreparation { _, entering in await latch.observe(entering) }
        let first = Task { try await session.run() }
        do {
            try await superHTTPEventually("first preparation held") { await latch.started == 1 }
            await #expect(throws: Binding.Failure.busy) { try await session.run() }
            #expect(await latch.started == 1)
        } catch {
            first.cancel(); await latch.release()
            _ = await first.result
            try await session.close()
            throw error
        }
        first.cancel(); await latch.release()
        _ = await first.result
        try await session.close()
    }

    @Test(.timeLimit(.minutes(2)))
    func cancellingWaitingEncoderLeavesFirstImageAndItsChargeIntact() async throws {
        let session = try await ConcurrentImageSession.make()
        let latch = ConcurrentImagePreparationLatch()
        await session.images.setTestPreparation { _, entering in await latch.observe(entering) }
        let baseline = await session.budget.outstandingReservedBytes()
        let first = Task { try await session.run() }
        var second: Task<Void, Error>?
        do {
            try await superHTTPEventually("first preparation held") { await latch.started == 1 }
            second = Task { try await session.run() }
            try await superHTTPEventually("both image quotes charged while one encoder waits") {
                await session.budget.outstandingReservedBytes() == baseline + 2 * session.quote
            }
            second?.cancel()
            await #expect(throws: CancellationError.self) { try await second?.value }
            #expect(await latch.started == 1)
            #expect(await session.budget.outstandingReservedBytes() == baseline + session.quote)
            await latch.release()
            try await first.value
            #expect(await session.budget.outstandingReservedBytes() == baseline)
        } catch {
            first.cancel(); second?.cancel(); await latch.release()
            _ = await first.result; _ = await second?.result
            try await session.close()
            throw error
        }
        try await session.close()
    }

    @Test(.timeLimit(.minutes(2)))
    func drainCancelsBothImagesAndWaitsForHeldPreparation() async throws {
        let session = try await ConcurrentImageSession.make()
        let latch = ConcurrentImagePreparationLatch()
        let drained = ConcurrentImageDrainObservation()
        await session.images.setTestPreparation { _, entering in await latch.observe(entering) }
        let baseline = await session.budget.outstandingReservedBytes()
        let first = Task { try await session.run() }
        var second: Task<Void, Error>?
        var drain: Task<Void, Error>?
        do {
            try await superHTTPEventually("first preparation held") { await latch.started == 1 }
            second = Task { try await session.run() }
            try await superHTTPEventually("both image quotes charged") {
                await session.budget.outstandingReservedBytes() == baseline + 2 * session.quote
            }
            drain = Task {
                try await session.images.drain()
                await drained.finish()
            }
            // The waiting encoder can cancel without touching the native tower.
            try await superHTTPEventually("waiting image refunded during drain") {
                await session.budget.outstandingReservedBytes() == baseline + session.quote
            }
            #expect(await !drained.finished)
            await #expect(throws: Binding.Failure.closed) { try await session.run() }
            await latch.release()
            try await drain?.value
            _ = await first.result; _ = await second?.result
            #expect(await drained.finished)
            #expect(await session.budget.outstandingReservedBytes() == baseline)
        } catch {
            first.cancel(); second?.cancel(); await latch.release()
            _ = await first.result; _ = await second?.result; _ = await drain?.result
            try await session.close()
            throw error
        }
        try await session.close()
    }

    @Test(.timeLimit(.minutes(2)))
    func secondImageRequiresItsFullQuoteBeforePreparation() async throws {
        let session = try await ConcurrentImageSession.make()
        let latch = ConcurrentImagePreparationLatch()
        await session.images.setTestPreparation { _, entering in await latch.observe(entering) }
        let available = session.budget.memoryHeadroomSnapshot().runtimeRemainingBytes
        try #require(available > session.quote)
        try #require(await session.budget.reserveBytes(requestID: "other-resident-work",
            bytes: available - session.quote))
        let baseline = await session.budget.outstandingReservedBytes()
        let first = Task { try await session.run() }
        do {
            try await superHTTPEventually("first image takes the remaining quote") { await latch.started == 1 }
            await #expect(throws: Binding.Failure.capacity) { try await session.run() }
            #expect(await latch.started == 1)
            #expect(await session.budget.outstandingReservedBytes() == baseline + session.quote)
        } catch {
            first.cancel(); await latch.release()
            _ = await first.result
            await session.budget.release(requestID: "other-resident-work")
            try await session.close()
            throw error
        }
        first.cancel(); await latch.release()
        _ = await first.result
        await session.budget.release(requestID: "other-resident-work")
        try await session.close()
    }

    @Test(.timeLimit(.minutes(2)))
    func twoImagesBoundAdmissionAndExcludeVideo() async throws {
        let session = try await ConcurrentImageSession.make()
        let latch = ConcurrentImagePreparationLatch()
        await session.images.setTestPreparation { _, entering in await latch.observe(entering) }
        let baseline = await session.budget.outstandingReservedBytes()
        let first = Task { try await session.run() }
        var second: Task<Void, Error>?
        do {
            try await superHTTPEventually("first preparation held") { await latch.started == 1 }
            // A video remains exclusive even while only one image is admitted.
            let body = try JSONSerialization.data(withJSONObject: [
                "model": session.owner.modelID,
                "messages": [["role": "user", "content": [["type": "video_url",
                    "video_url": ["url": "data:video/mp4;base64,AAAAGGZ0eXA="]]]]],
            ])
            let plan = try NemotronSuperRequestPlan(body: body)
            await #expect(throws: Binding.Failure.busy) {
                try await session.images.runEncoded(body: body, plan: plan, templateBytes: Data([1])) { _ in
                    Issue.record("video overlapped an active image")
                }
            }
            second = Task { try await session.run() }
            try await superHTTPEventually("both image quotes charged") {
                await session.budget.outstandingReservedBytes() == baseline + 2 * session.quote
            }
            await #expect(throws: Binding.Failure.busy) { try await session.run() }
            #expect(await latch.started == 1)
        } catch {
            first.cancel(); second?.cancel(); await latch.release()
            _ = await first.result; _ = await second?.result
            try await session.close()
            throw error
        }
        first.cancel(); second?.cancel(); await latch.release()
        _ = await first.result; _ = await second?.result
        try await session.close()
    }
}

/// Real installed model and shared budget; the latch only delays preparation.
private struct ConcurrentImageSession: @unchecked Sendable {
    let fixture: SuperMTPInstalledFixture.Installation
    let owner: NemotronSuperLocalBridgeBuilder.Owner
    let images: NemotronSuperLocalImageBinding
    let budget: GlobalKVCacheBudget
    let lease: PendingModelLoadLease
    let quote: UInt64
    let encoded: Bool

    static func make(flag: String = "1", width: Int = 4, encoded: Bool = false) async throws -> Self {
        let fixture = try SuperMTPInstalledFixture(
            radioDimensions: encoded ? SuperMTPInstalledFixture.encodedImageTower : nil).make()
        let contextLength = encoded ? 1024 : 64
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 16 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-concurrent-lifecycle",
            weightBytes: UInt64(fixture.installed.receipt.payloadBytes), minimumKVBytes: 4 << 30))
        var environment = [NemotronSuperLocalBridgeBuilder.maxConcurrentKey: String(width)]
        if !flag.isEmpty { environment[NemotronSuperLocalBridgeBuilder.concurrentImagesKey] = flag }
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: fixture.installed,
            tokenizer: TokenizerHandle(SuperSyntheticImageTokenizer()), eosTokenIDs: [],
            sizing: .init(weightsBytes: fixture.installed.receipt.payloadBytes,
                fp16KVBytesPerToken: 64, maxContextLength: contextLength, defaultMaxTokens: 16),
            kvBytesCapacity: 4 << 30, kvBudget: budget, loadLease: lease,
            construction: fixture.construction, environment: environment)
        let quote: UInt64
        if encoded {
            let body = try encodedBody()
            let plan = try NemotronSuperRequestPlan(body: body)
            let images = try NemotronSuperLocalImageBinding.encodedBody(plan).images
            quote = try NemotronSuperLocalImageBinding.encodedPlan(images, contextLength: contextLength).totalBytes
                + NemotronSuperLocalImageBinding.encodedHeaderQuote(bodyBytes: body.count,
                    templateBytes: template().count)
        } else {
            quote = try NemotronSuperLocalImageBinding.preparationQuote(input, contextLength: contextLength).totalBytes
        }
        return Self(fixture: fixture, owner: owner, images: try owner.localImageBinding(),
            budget: budget, lease: lease, quote: quote, encoded: encoded)
    }

    private static var input: NemotronSuperLocalImageBinding.Input {
        .init(promptTokens: [1, 18, 2], normalizedImages: [MLXArray.zeros([1, 1, 4, 4])])
    }

    func run() async throws {
        let result = ConcurrentImageResult()
        if encoded {
            let body = try Self.encodedBody()
            try await images.runEncoded(body: body, plan: NemotronSuperRequestPlan(body: body),
                templateBytes: Self.template()) { await result.record($0) }
        } else {
            try await images.run(request: .init(model: owner.modelID, messages: [], temperature: 0, max_tokens: 16),
                input: Self.input) { await result.record($0) }
        }
        #expect(await result.errors.isEmpty)
        #expect(await result.completions == [16])
    }

    private static func template() throws -> Data {
        try #require(Data(base64Encoded: superImagePinnedTemplateBase64, options: .ignoreUnknownCharacters))
    }

    private static func encodedBody() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": NemotronSuperLocalBinding.modelID, "max_tokens": 16, "temperature": 0,
            "messages": [["role": "user", "content": [["type": "image_url", "image_url": [
                "url": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP4z8BAEiJN9aiGUQ1DSgMAkPn/Afnh+ngAAAAASUVORK5CYII=",
            ]]]]],
        ], options: [.sortedKeys])
    }

    private actor ConcurrentImageResult {
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

    func close() async throws {
        try await owner.closeAfterDrain()
        #expect(fixture.residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}

private actor ConcurrentImagePreparationLatch {
    private(set) var started = 0
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func observe(_ entering: Bool) async {
        guard entering else { return }
        started += 1
        if started == 1 && !released {
            await withCheckedContinuation { continuation = $0 }
        }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ConcurrentImageDrainObservation {
    private(set) var finished = false
    func finish() { finished = true }
}
