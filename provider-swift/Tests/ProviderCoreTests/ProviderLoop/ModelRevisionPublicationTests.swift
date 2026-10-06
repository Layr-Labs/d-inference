import Foundation
import Testing
@testable import ProviderCore

/// Hold the client actor at a real cross-actor publication boundary. The
/// bounded blocking call is test-only and released by every exit path.
private final class RevisionClientGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    var isEntered: Bool { lock.withLock { entered } }
    func block() {
        lock.withLock { entered = true }
        _ = semaphore.wait(timeout: .now() + 15)
    }
    func release() { semaphore.signal() }
}

private final class RevisionPublicationMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [ModelInfo] = []
    func record(_ message: OutboundMessage) {
        if case .modelsUpdate(let models) = message { lock.withLock { updates += models } }
    }
    var models: [ModelInfo] { lock.withLock { updates } }
}

private extension CoordinatorClient {
    func revisionTestBlock(_ gate: RevisionClientGate) { gate.block() }
    func revisionTestHash(_ id: String) -> String? { modelWeightHashOverrides?[id] }
}

private extension ProviderLoop {
    func revisionTestInstallClient(send: SendHandle, previous: String) -> CoordinatorClient {
        let previousInfo = ModelInfo(id: previous, modelType: "gpt_oss", sizeBytes: 3, estimatedMemoryGb: 0.1, weightHash: "previous")
        advertisedModels[previous] = previousInfo
        modelHashes[previous] = "previous"
        liveModelHashes[previous] = "previous"
        let client = CoordinatorClient(config: .init(url: loopConfig.coordinatorURL,
            hardware: loopConfig.hardware, models: Array(advertisedModels.values), backendName: "test"),
            stats: AtomicProviderStats(), state: state)
        coordinatorClient = client
        outboundSend = send
        return client
    }
    func revisionTestWaitingForReslice() -> Bool { !resliceGateWaiters.isEmpty }
    func revisionTestWaitingForClient(_ id: String, hash: String) -> Bool {
        modelHashes[id] == hash && !isReslicing && prefetchPublicationCounts[id] != nil
    }
    func revisionTestPrevious(_ id: String) -> String? { desiredSwapDrop[id] }
    func revisionTestPendingAdvertise() -> Set<String> { pendingAdvertise }
}

@Suite("Model revision publication", .serialized)
struct ModelRevisionPublicationTests {
    private func waitFor(_ condition: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await condition())
    }

    @Test("superseding a publication during reserve acquisition preserves alias lineage and rolls back")
    func supersededDuringReserve() async throws {
        let f = try await RevisionActivationFixture.make()
        defer { f.clean() }
        let messages = RevisionPublicationMessages()
        let send = SendHandle { messages.record($0) }
        let previous = "test-org/previous"
        let client = await f.loop.revisionTestInstallClient(send: send, previous: previous)
        try await f.loop.beginModelRevisionDrain(f.staged)
        await f.loop.acquireResliceGateForTesting()
        let attempt = Task { try await f.loop.commitModelRevisionIfIdle(f.staged) }
        do {
            try await waitFor { await f.loop.revisionTestWaitingForReslice() }
        } catch {
            await f.loop.releaseResliceGateForTesting()
            _ = await attempt.result
            throw error
        }
        await f.loop.reconcileDesiredModels([.init(modelName: "alias", desiredBuild: f.id,
            previousBuild: previous, revision: "old", aggregateSHA256: f.oldHash)], send: send)
        await f.loop.releaseResliceGateForTesting()
        await #expect(throws: CancellationError.self) { try await attempt.value }
        #expect(await f.loop.revisionTestPrevious(f.id) == previous)
        #expect(await f.loop.isModelAdvertised(previous))
        #expect(await f.loop.revisionTestPendingAdvertise().isEmpty)
        #expect(await f.loop.revisionTestHash(f.id) == f.oldHash)
        #expect(ModelScanner.resolveLocalPath(modelID: f.id) == f.oldDirectory)
        #expect(!messages.models.contains { $0.weightHash == f.newHash })
        #expect(await client.currentAdvertisedModels().first { $0.id == f.id }?.weightHash == f.oldHash)
        #expect(await client.revisionTestHash(f.id) == f.oldHash)
        await f.loop.finishModelRevisionDrain(f.staged)
        // The retry/converged path can still retire the alias's previous build.
        await f.loop.reconcileDesiredModels([.init(modelName: "alias", desiredBuild: f.id,
            previousBuild: previous, revision: "old", aggregateSHA256: f.oldHash)], send: send)
        #expect(await !f.loop.isModelAdvertised(previous))
        #expect(await f.loop.revisionTestPrevious(f.id) == nil)
        #expect(await !client.currentAdvertisedModels().contains { $0.id == previous })
    }

    @Test("client suspension cannot announce a superseded or cancelled revision", arguments: [false, true])
    func invalidatedDuringClientPublication(cancelOnly: Bool) async throws {
        let f = try await RevisionActivationFixture.make()
        defer { f.clean() }
        let messages = RevisionPublicationMessages()
        let send = SendHandle { messages.record($0) }
        let previous = "test-org/previous"
        let client = await f.loop.revisionTestInstallClient(send: send, previous: previous)
        await f.loop.reconcileDesiredModels([.init(modelName: "alias", desiredBuild: f.id,
            previousBuild: previous, revision: "new", aggregateSHA256: f.newHash)], send: send)
        try await f.loop.beginModelRevisionDrain(f.staged)
        let gate = RevisionClientGate()
        defer { gate.release() }
        let blocker = Task.detached { await client.revisionTestBlock(gate) }
        try await waitFor { gate.isEntered }
        let attempt = Task { try await f.loop.commitModelRevisionIfIdle(f.staged) }
        do {
            try await waitFor { await f.loop.revisionTestWaitingForClient(f.id, hash: f.newHash) }
        } catch {
            attempt.cancel()
            gate.release()
            await blocker.value
            _ = await attempt.result
            throw error
        }
        if cancelOnly {
            attempt.cancel()
        } else {
            // Same hash, different version: the provisional local advertisement
            // must not be mistaken for an already-converged desired revision.
            await f.loop.reconcileDesiredModels([.init(modelName: "alias", desiredBuild: f.id,
                previousBuild: previous, revision: "newer", aggregateSHA256: f.newHash)], send: send)
        }
        gate.release()
        await blocker.value
        await #expect(throws: CancellationError.self) { try await attempt.value }
        #expect(await f.loop.revisionTestPrevious(f.id) == previous)
        #expect(await f.loop.isModelAdvertised(previous))
        #expect(await f.loop.revisionTestHash(f.id) == f.oldHash)
        #expect(ModelScanner.resolveLocalPath(modelID: f.id) == f.oldDirectory)
        #expect(!messages.models.contains { $0.weightHash == f.newHash })
        #expect(await client.currentAdvertisedModels().first { $0.id == f.id }?.weightHash == f.oldHash)
        #expect(await client.revisionTestHash(f.id) == f.oldHash)
        #expect(await client.currentAdvertisedModels().contains { $0.id == previous })
        #expect(await f.loop.revisionTestPendingAdvertise().isEmpty)
        await f.loop.finishModelRevisionDrain(f.staged)
        #expect(await !f.loop.revisionTestDraining(f.id))
        // Retry the verified revision and consume the preserved lineage only
        // after successful publication.
        await f.loop.reconcileDesiredModels([.init(modelName: "alias", desiredBuild: f.id,
            previousBuild: previous, revision: "new", aggregateSHA256: f.newHash)], send: send)
        let lease = try await ModelArtifactWriteLease.acquire(modelID: f.id)
        let retry = StagedModelRevision(entry: f.staged.entry, directory: f.newDirectory,
            info: f.staged.info, lease: lease, totalSizeBytes: f.staged.totalSizeBytes)
        try await f.loop.beginModelRevisionDrain(retry)
        #expect(try await f.loop.commitModelRevisionIfIdle(retry))
        await f.loop.finishModelRevisionDrain(retry)
        #expect(await !f.loop.isModelAdvertised(previous))
        #expect(await f.loop.revisionTestPrevious(f.id) == nil)
        #expect(await !client.currentAdvertisedModels().contains { $0.id == previous })
        #expect(await f.loop.pendingModelRevisions().isEmpty)
    }
}
