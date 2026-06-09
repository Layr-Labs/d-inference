import Foundation
import Testing
@testable import ProviderCore

// MARK: - Test doubles

/// Records every status emission so tests can assert the lifecycle.
private final class RecordingSink: PrefetchStatusSink, @unchecked Sendable {
    struct Event: Equatable {
        let modelId: String
        let status: ProviderMessage.PrefetchModelStatus.Status
        let bytesDone: Int64
        let bytesTotal: Int64
        let error: String?
    }

    private let lock = NSLock()
    private var _events: [Event] = []

    func emit(
        modelId: String,
        status: ProviderMessage.PrefetchModelStatus.Status,
        bytesDone: Int64,
        bytesTotal: Int64,
        error: String?
    ) {
        lock.lock()
        _events.append(Event(modelId: modelId, status: status, bytesDone: bytesDone, bytesTotal: bytesTotal, error: error))
        lock.unlock()
    }

    var events: [Event] { lock.lock(); defer { lock.unlock() }; return _events }
    var statuses: [ProviderMessage.PrefetchModelStatus.Status] { events.map(\.status) }
    func terminal() -> Event? { events.last(where: { $0.status == .verified || $0.status == .failed }) }
}

private enum FakePrefetchError: Error, LocalizedError {
    case hashMismatch
    var errorDescription: String? { "aggregate hash mismatch (fake)" }
}

/// Configurable fake `ModelPrefetcher`. Counts invocations (for coalescing
/// assertions), can emit byte progress, can fail, and can block on a gate so a
/// test can cancel mid-flight.
private final class FakePrefetcher: ModelPrefetcher, @unchecked Sendable {
    enum Behavior {
        case success(total: Int64, steps: Int)
        case failHashMismatch
        case blockUntilCancelled
    }

    private let behavior: Behavior
    private let lock = NSLock()
    private var _callCount = 0
    /// Signalled when a blocking prefetch has actually started (so a test can
    /// cancel only after the download body is running).
    let started = AsyncSemaphore()

    init(_ behavior: Behavior) { self.behavior = behavior }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }

    func prefetchToDisk(
        modelID: String,
        onByteProgress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws {
        lock.withLock { _callCount += 1 }
        switch behavior {
        case .success(let total, let steps):
            for i in 1...max(1, steps) {
                try Task.checkCancellation()
                let done = Int64(Double(total) * Double(i) / Double(max(1, steps)))
                onByteProgress(done, total)
                // Tiny yield so progress callbacks interleave realistically.
                try await Task.sleep(for: .milliseconds(1))
            }
        case .failHashMismatch:
            onByteProgress(50, 100)
            throw FakePrefetchError.hashMismatch
        case .blockUntilCancelled:
            started.signal()
            // Block forever until the task is cancelled.
            while true {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}

/// Prefetcher that records the ORDER in which each model's download body begins
/// and blocks each one on a per-model gate the test releases explicitly. Lets a
/// priority-ordering test assert which queued request the scheduler dispatches
/// next when an in-flight slot frees.
private final class GatedPrefetcher: ModelPrefetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _startOrder: [String] = []
    /// One-shot gate per model: a download body parks here until released.
    private var gates: [String: AsyncSemaphore] = [:]
    /// Signalled each time a NEW download body starts (so the test can wait for
    /// the in-flight one to actually be running before enqueuing the rest).
    let bodyStarted = AsyncSemaphore()

    var startOrder: [String] { lock.lock(); defer { lock.unlock() }; return _startOrder }

    /// Release the (single) in-flight model so its download completes, freeing
    /// the slot for the scheduler to dispatch the next queued waiter.
    func release(_ modelId: String) {
        let gate: AsyncSemaphore = lock.withLock {
            if let g = gates[modelId] { return g }
            let g = AsyncSemaphore()
            gates[modelId] = g
            return g
        }
        gate.signal()
    }

    func prefetchToDisk(
        modelID: String,
        onByteProgress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws {
        let gate: AsyncSemaphore = lock.withLock {
            _startOrder.append(modelID)
            if let g = gates[modelID] { return g }
            let g = AsyncSemaphore()
            gates[modelID] = g
            return g
        }
        bodyStarted.signal()
        await gate.wait()
        try Task.checkCancellation()
    }
}

/// Async semaphore that counts signals so multiple `bodyStarted` events can be
/// awaited in sequence without losing edges. Counting semantics: each `signal()`
/// adds a permit, each `wait()` consumes one (parking if none are available), so
/// N signals release exactly N waiters regardless of interleaving.
private final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var permits = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty {
                permits += 1
                return nil
            }
            return waiters.removeFirst()
        }
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if permits > 0 {
                    permits -= 1
                    return true
                }
                waiters.append(cont)
                return false
            }
            if resumeNow { cont.resume() }
        }
    }
}

// MARK: - Helpers

/// Poll `condition` until true or timeout. Returns whether it became true.
private func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Blocks (cancellation-ignoring) on a DispatchSemaphore from a background
/// queue, bridged to async — models awaiting an uninterruptible synchronous
/// computation (like a weight hash).
private func blockUntilSignalled(_ semaphore: DispatchSemaphore) async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            semaphore.wait()
            cont.resume()
        }
    }
}

private func makeCoordinator(
    prefetcher: any ModelPrefetcher,
    preCheck: @escaping @Sendable (String) async -> PrefetchPreCheck = { _ in .needsFetch },
    onVerified: @escaping @Sendable (String) async -> Void = { _ in }
) -> ModelPrefetchCoordinator {
    ModelPrefetchCoordinator(prefetcher: prefetcher, preCheck: preCheck, onVerified: onVerified)
}

// MARK: - Tests

@Suite("ModelPrefetchCoordinator", .serialized)
struct ModelPrefetchCoordinatorTests {

    @Test("success emits started → downloading → verified and fires re-advertise")
    func successLifecycle() async throws {
        let prefetcher = FakePrefetcher(.success(total: 1000, steps: 4))
        let advertised = AdvertisedRecorder()
        let coord = makeCoordinator(
            prefetcher: prefetcher,
            onVerified: { id in advertised.record(id) }
        )
        let sink = RecordingSink()

        await coord.handlePrefetch(modelId: "org/m", priority: 1, sink: sink)

        let done = await waitUntil { sink.terminal() != nil }
        #expect(done)

        let statuses = sink.statuses
        #expect(statuses.first == .started)
        #expect(statuses.contains(.downloading))
        #expect(statuses.last == .verified)
        // started precedes the first downloading, which precedes verified.
        let firstDown = statuses.firstIndex(of: .downloading)
        let verifiedIdx = statuses.firstIndex(of: .verified)
        #expect(firstDown != nil && verifiedIdx != nil && firstDown! < verifiedIdx!)
        // Re-advertise hook fired exactly once for the verified model.
        #expect(advertised.ids == ["org/m"])
        #expect(prefetcher.callCount == 1)
        // A downloading update carried real progress bytes.
        let down = sink.events.first { $0.status == .downloading }
        #expect(down?.bytesTotal == 1000)
        #expect((down?.bytesDone ?? 0) > 0)
    }

    @Test("already-available short-circuits to verified without downloading")
    func alreadyAvailableShortCircuits() async throws {
        let prefetcher = FakePrefetcher(.success(total: 100, steps: 2))
        let advertised = AdvertisedRecorder()
        let coord = makeCoordinator(
            prefetcher: prefetcher,
            preCheck: { _ in .alreadyAvailable },
            onVerified: { id in advertised.record(id) }
        )
        let sink = RecordingSink()

        await coord.handlePrefetch(modelId: "org/already", priority: 1, sink: sink)
        let done = await waitUntil { sink.terminal() != nil }
        #expect(done)

        #expect(sink.statuses == [.started, .verified])
        #expect(!sink.statuses.contains(.downloading))
        #expect(prefetcher.callCount == 0)        // never downloaded
        #expect(advertised.ids == ["org/already"]) // still re-advertised
    }

    @Test("hash mismatch yields failed with an error and no verified")
    func hashMismatchFails() async throws {
        let prefetcher = FakePrefetcher(.failHashMismatch)
        let advertised = AdvertisedRecorder()
        let coord = makeCoordinator(
            prefetcher: prefetcher,
            onVerified: { id in advertised.record(id) }
        )
        let sink = RecordingSink()

        await coord.handlePrefetch(modelId: "org/bad", priority: 1, sink: sink)
        let done = await waitUntil { sink.terminal() != nil }
        #expect(done)

        let terminal = sink.terminal()
        #expect(terminal?.status == .failed)
        #expect(terminal?.error?.contains("hash mismatch") == true)
        #expect(!sink.statuses.contains(.verified))
        #expect(advertised.ids.isEmpty) // re-advertise NOT fired on failure
    }

    @Test("cancellation (shutdown) stops the task without emitting verified")
    func cancellationStopsWithoutVerified() async throws {
        let prefetcher = FakePrefetcher(.blockUntilCancelled)
        let advertised = AdvertisedRecorder()
        let coord = makeCoordinator(
            prefetcher: prefetcher,
            onVerified: { id in advertised.record(id) }
        )
        let sink = RecordingSink()

        await coord.handlePrefetch(modelId: "org/blocked", priority: 1, sink: sink)
        // Wait until the download body is actually running.
        await prefetcher.started.wait()
        #expect(sink.statuses == [.started])

        await coord.shutdown(timeout: .seconds(3))

        // No terminal verified/failed leaked from a cancelled task.
        #expect(!sink.statuses.contains(.verified))
        #expect(advertised.ids.isEmpty)
        let count = await coord.inFlightCount()
        #expect(count == 0)
    }

    @Test("shutdown returns within its timeout even if a task is parked on an uninterruptible hook")
    func shutdownIsBounded() async throws {
        // Prefetch succeeds quickly, then onVerified blocks on an UNINTERRUPTIBLE
        // synchronous wait (a DispatchSemaphore the test never signals until
        // after the assertion). This faithfully models `applyVerifiedPrefetch`
        // awaiting a detached synchronous `WeightHasher.computeHash`, which task
        // cancellation cannot stop. shutdown(timeout:) must still return near its
        // bound rather than blocking on the parked task.
        let prefetcher = FakePrefetcher(.success(total: 10, steps: 1))
        let verifyEntered = AsyncSemaphore()
        let release = DispatchSemaphore(value: 0)
        let coord = makeCoordinator(
            prefetcher: prefetcher,
            onVerified: { _ in
                verifyEntered.signal()
                // Await a synchronous, cancellation-IGNORING block run off a
                // background queue — exactly how applyVerifiedPrefetch awaits a
                // detached synchronous WeightHasher.computeHash. Cancelling the
                // prefetch task cannot stop it; only the test's signal releases it.
                await blockUntilSignalled(release)
            }
        )
        let sink = RecordingSink()
        await coord.handlePrefetch(modelId: "org/stuck", priority: 1, sink: sink)
        await verifyEntered.wait() // task is now parked inside onVerified

        let start = ContinuousClock.now
        await coord.shutdown(timeout: .milliseconds(200))
        let elapsed = ContinuousClock.now - start
        // Returns near the 200ms bound, NOT blocked on the uninterruptible hook.
        #expect(elapsed < .seconds(5))
        // Let the parked task finish so the test process doesn't leak a blocked
        // thread.
        release.signal()
    }

    @Test("higher-priority queued prefetch is serviced before lower-priority ones")
    func priorityOrdering() async throws {
        // Single in-flight slot: while one download runs, the rest queue and the
        // scheduler must dispatch them strictly by priority (highest first).
        let prefetcher = GatedPrefetcher()
        let advertised = AdvertisedRecorder()
        let coord = ModelPrefetchCoordinator(
            prefetcher: prefetcher,
            preCheck: { _ in .needsFetch },
            onVerified: { id in advertised.record(id) },
            maxConcurrent: 1
        )

        let sinkLow = RecordingSink()
        let sinkHigh = RecordingSink()
        let sinkMid = RecordingSink()

        // 1) Low-priority request dispatches immediately and parks in its body.
        await coord.handlePrefetch(modelId: "org/low", priority: 1, sink: sinkLow)
        await prefetcher.bodyStarted.wait()
        let runningFirst = await coord.inFlightCount()
        #expect(runningFirst == 1)
        #expect(prefetcher.startOrder == ["org/low"]) // low is the one in flight

        // 2) While low is in flight, enqueue mid then high (mid arrives FIRST but
        //    is lower priority, proving the scheduler orders by priority, not by
        //    arrival).
        await coord.handlePrefetch(modelId: "org/mid", priority: 5, sink: sinkMid)
        await coord.handlePrefetch(modelId: "org/high", priority: 10, sink: sinkHigh)
        let queued = await coord.queuedCount()
        #expect(queued == 2)
        let stillOne = await coord.inFlightCount()
        #expect(stillOne == 1) // bounded concurrency: still just low running

        // 3) Release low → slot frees → scheduler must pick HIGH (10) over MID (5).
        prefetcher.release("org/low")
        await prefetcher.bodyStarted.wait()
        #expect(prefetcher.startOrder == ["org/low", "org/high"])
        let queuedAfterHigh = await coord.queuedCount()
        #expect(queuedAfterHigh == 1) // mid still waiting

        // 4) Release high → slot frees → only MID remains.
        prefetcher.release("org/high")
        await prefetcher.bodyStarted.wait()
        #expect(prefetcher.startOrder == ["org/low", "org/high", "org/mid"])

        // 5) Drain: release mid and let everything verify.
        prefetcher.release("org/mid")
        let allDone = await waitUntil {
            sinkLow.terminal() != nil && sinkHigh.terminal() != nil && sinkMid.terminal() != nil
        }
        #expect(allDone)
        #expect(sinkLow.terminal()?.status == .verified)
        #expect(sinkHigh.terminal()?.status == .verified)
        #expect(sinkMid.terminal()?.status == .verified)
        // All three re-advertised (order: completion order = low, high, mid).
        #expect(Set(advertised.ids) == ["org/low", "org/high", "org/mid"])
        let drained = await coord.inFlightCount()
        #expect(drained == 0)

        await coord.shutdown(timeout: .seconds(3))
    }

    @Test("a more-urgent duplicate promotes a queued request ahead of the queue")
    func duplicatePromotesPriority() async throws {
        // low runs; A (prio 2) and B (prio 3) queue. A second request for A with
        // a HIGHER priority (5) must promote A ahead of B, without a 2nd download.
        let prefetcher = GatedPrefetcher()
        let coord = ModelPrefetchCoordinator(
            prefetcher: prefetcher,
            preCheck: { _ in .needsFetch },
            onVerified: { _ in },
            maxConcurrent: 1
        )
        let sinkLow = RecordingSink()
        let sinkA1 = RecordingSink()
        let sinkB = RecordingSink()
        let sinkA2 = RecordingSink()

        await coord.handlePrefetch(modelId: "org/low", priority: 1, sink: sinkLow)
        await prefetcher.bodyStarted.wait()

        await coord.handlePrefetch(modelId: "org/A", priority: 2, sink: sinkA1)
        await coord.handlePrefetch(modelId: "org/B", priority: 3, sink: sinkB)
        // Re-request A at higher priority than B → promotes A. Coalesces (no new
        // queue entry, no second download).
        await coord.handlePrefetch(modelId: "org/A", priority: 5, sink: sinkA2)
        let queued = await coord.queuedCount()
        #expect(queued == 2) // still only A and B queued (A coalesced)

        prefetcher.release("org/low")
        await prefetcher.bodyStarted.wait()
        // A (now prio 5) jumps ahead of B (prio 3).
        #expect(prefetcher.startOrder == ["org/low", "org/A"])

        prefetcher.release("org/A")
        await prefetcher.bodyStarted.wait()
        #expect(prefetcher.startOrder == ["org/low", "org/A", "org/B"])
        // A was downloaded exactly once despite two requests (coalesced).
        let aStarts = prefetcher.startOrder.filter { $0 == "org/A" }.count
        #expect(aStarts == 1)
        // Both A subscribers see the same lifecycle (each got its own .started).
        #expect(sinkA1.statuses.first == .started)
        #expect(sinkA2.statuses.first == .started)

        prefetcher.release("org/B")
        await coord.shutdown(timeout: .seconds(3))
    }

    @Test("duplicate concurrent prefetches for the same model coalesce to one download")
    func duplicatesCoalesce() async throws {
        let prefetcher = FakePrefetcher(.blockUntilCancelled)
        let coord = makeCoordinator(prefetcher: prefetcher)
        let sinkA = RecordingSink()
        let sinkB = RecordingSink()

        await coord.handlePrefetch(modelId: "org/dup", priority: 1, sink: sinkA)
        await prefetcher.started.wait() // first task is running
        // Second request for the SAME id while the first is in flight.
        await coord.handlePrefetch(modelId: "org/dup", priority: 1, sink: sinkB)

        // Both subscribers got their own `.started`.
        #expect(sinkA.statuses.first == .started)
        #expect(sinkB.statuses.first == .started)
        // Only ONE underlying download task exists, and the fake was invoked once.
        let inflight = await coord.inFlightCount()
        #expect(inflight == 1)
        #expect(prefetcher.callCount == 1)

        await coord.shutdown(timeout: .seconds(3))
    }
}

/// Thread-safe recorder for the verified→re-advertise hook.
private final class AdvertisedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _ids: [String] = []
    func record(_ id: String) { lock.lock(); _ids.append(id); lock.unlock() }
    var ids: [String] { lock.lock(); defer { lock.unlock() }; return _ids }
}

/// Thread-safe recorder for outbound messages flowing through a `SendHandle`,
/// so tests can assert which `models_update` payloads were emitted. Each entry
/// in `modelsUpdates()` is the `models` array from one emitted update.
private final class OutboundRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [OutboundMessage] = []
    func record(_ message: OutboundMessage) { lock.lock(); _messages.append(message); lock.unlock() }
    func modelsUpdates() -> [[ModelInfo]] {
        lock.lock(); defer { lock.unlock() }
        return _messages.compactMap { msg in
            if case .modelsUpdate(let models) = msg { return models }
            return nil
        }
    }
}

/// Fake prefetcher that succeeds without touching the network — used by the
/// ProviderLoop-level integration test where a valid snapshot is pre-seeded on
/// disk so `applyVerifiedPrefetch`'s scan + weight-hash succeed.
private final class NoopSuccessPrefetcher: ModelPrefetcher, @unchecked Sendable {
    func prefetchToDisk(
        modelID: String,
        onByteProgress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws {
        onByteProgress(10, 10)
    }
}

// MARK: - ProviderLoop integration (real actor, real disk, no GPU/network)

@Suite("ProviderLoop prefetch integration", .serialized)
struct ProviderLoopPrefetchTests {

    /// Seed a minimal valid MLX snapshot (config.json + one .safetensors) in the
    /// HuggingFace cache so the scanner + WeightHasher can read it.
    private func seedSnapshot(modelID: String) throws -> URL {
        let snapshot = ModelDownloader.cacheSnapshotDirectory(for: modelID)
        let modelDir = ModelDownloader.cacheModelDirectory(for: modelID)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let refs = modelDir.appendingPathComponent("refs", isDirectory: true)
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        try Data(#"{"model_type":"qwen3"}"#.utf8).write(to: snapshot.appendingPathComponent("config.json"))
        try Data("fake mlx weight bytes".utf8).write(to: snapshot.appendingPathComponent("model.safetensors"))
        try "local".write(to: refs.appendingPathComponent("main"), atomically: true, encoding: .utf8)
        return modelDir
    }

    private func makeLoop(models: [ModelInfo], maxModelSlots: UInt64 = 2) throws -> ProviderLoop {
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546
            ),
            models: models,
            config: ProviderConfig(
                provider: ProviderSettings(name: "prefetch-unit-test", memoryReserveGB: 1),
                backend: BackendSettings(continuousBatching: true, idleTimeoutMins: 0, maxModelSlots: maxModelSlots),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
            )
        )
        return try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
    }

    private func makeClient() -> CoordinatorClient {
        let config = CoordinatorClientConfig(
            url: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546
            ),
            models: [],
            backendName: "mlx-swift"
        )
        return CoordinatorClient(config: config, stats: AtomicProviderStats(), state: ProviderState())
    }

    @Test("verified prefetch advertises the new build and records its weight hash")
    func verifiedPrefetchAdvertisesAndHashes() async throws {
        let startupModel = ModelInfo(id: "org/startup", sizeBytes: 1, estimatedMemoryGb: 1)
        let newModelID = "org/prefetched-\(UUID().uuidString)"
        let modelDir = try seedSnapshot(modelID: newModelID)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        let loop = try makeLoop(models: [startupModel])
        let client = makeClient()
        let coord = ModelPrefetchCoordinator(
            prefetcher: NoopSuccessPrefetcher(),
            preCheck: { _ in .needsFetch },
            onVerified: { id in await loop.applyVerifiedPrefetch(modelId: id) }
        )
        // Capture outbound messages so we can assert a `models_update` is emitted
        // on verify (the authoritative ModelInfo + weight hash for the coordinator
        // to cross-check before routing). This is the SAME send handle used for
        // prefetch status, injected here for the test.
        let outbound = OutboundRecorder()
        let capturingSend = SendHandle { outbound.record($0) }
        await loop.installPrefetchCoordinatorForTesting(coord, client: client, send: capturingSend)

        // Before: only the startup model is advertised.
        let beforeCount = await loop.advertisedModelCount()
        #expect(beforeCount == 1)
        let newAdvertisedBefore = await loop.isModelAdvertised(newModelID)
        #expect(!newAdvertisedBefore)

        // Fire a prefetch via the real handler.
        await loop.handlePrefetchModelRequest(modelId: newModelID, priority: 1, send: capturingSend)

        // Wait for the new build to be advertised (verified → re-advertise hook).
        let advertised = await waitUntil(timeout: .seconds(10)) {
            await loop.isModelAdvertised(newModelID)
        }
        #expect(advertised)
        // Both startup and prefetched are advertised (transition keeps old).
        let afterCount = await loop.advertisedModelCount()
        #expect(afterCount == 2)
        #expect(await loop.isModelAdvertised("org/startup"))
        // The coordinator client also learned the new build for the next register.
        let clientModels = await client.currentAdvertisedModels().map(\.id)
        #expect(clientModels.contains(newModelID))
        // The weight hash was recorded so attestation/challenge covers the
        // hotswapped model (finding 2 fix).
        let recordedHash = await loop.modelHashForTesting(newModelID)
        #expect(recordedHash != nil && !(recordedHash!.isEmpty))
        // And it rides on the advertised ModelInfo for reconnect registration.
        let advertisedInfo = await client.currentAdvertisedModels().first { $0.id == newModelID }
        #expect(advertisedInfo?.weightHash == recordedHash)

        // A `models_update` outbound message was emitted carrying the build id
        // AND a non-empty weight hash (the security-gap fix: the coordinator can
        // now cross-check the verified build's hash before routing).
        let emittedUpdate = await waitUntil(timeout: .seconds(5)) {
            outbound.modelsUpdates().contains { models in
                models.contains { $0.id == newModelID }
            }
        }
        #expect(emittedUpdate)
        let updatedInfo = outbound.modelsUpdates()
            .flatMap { $0 }
            .first { $0.id == newModelID }
        #expect(updatedInfo != nil)
        #expect(updatedInfo?.weightHash == recordedHash)
        #expect(!(updatedInfo?.weightHash?.isEmpty ?? true))
    }

    @Test("verified prefetch whose snapshot can't be scanned is NOT advertised")
    func verifiedPrefetchUnscannableSnapshotNotAdvertised() async throws {
        // The prefetch reports verified (download succeeded) but NO snapshot is on
        // disk, so `scanVerifiedModelInfo` returns nil. The provider must NOT
        // advertise a synthetic zero-size ModelInfo (which would be routed with
        // estimatedMemoryGb == 0, bypassing memory sizing) — it advertises nothing
        // and emits no models_update, so the coordinator never routes the build.
        let startupModel = ModelInfo(id: "org/startup", sizeBytes: 1, estimatedMemoryGb: 1)
        let newModelID = "org/unscannable-\(UUID().uuidString)"
        // Deliberately do NOT seed a snapshot; make sure no stray dir exists.
        let modelDir = ModelDownloader.cacheModelDirectory(for: newModelID)
        try? FileManager.default.removeItem(at: modelDir)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        let loop = try makeLoop(models: [startupModel])
        let client = makeClient()
        let verifiedCalls = AdvertisedRecorder()
        let coord = ModelPrefetchCoordinator(
            prefetcher: NoopSuccessPrefetcher(), // "downloads" without touching disk
            preCheck: { _ in .needsFetch },
            onVerified: { id in
                await loop.applyVerifiedPrefetch(modelId: id)
                verifiedCalls.record(id) // record AFTER applyVerifiedPrefetch completes
            }
        )
        let outbound = OutboundRecorder()
        let capturingSend = SendHandle { outbound.record($0) }
        await loop.installPrefetchCoordinatorForTesting(coord, client: client, send: capturingSend)

        await loop.handlePrefetchModelRequest(modelId: newModelID, priority: 1, send: capturingSend)

        // Wait until the verify→applyVerifiedPrefetch hook has fully run.
        let ran = await waitUntil(timeout: .seconds(10)) { verifiedCalls.ids.contains(newModelID) }
        #expect(ran)

        // It must NOT have advertised the unscannable build, anywhere.
        #expect(!(await loop.isModelAdvertised(newModelID)))
        #expect(await loop.advertisedModelCount() == 1) // only the startup model
        #expect(!(await client.currentAdvertisedModels().map(\.id).contains(newModelID)))
        #expect(!outbound.modelsUpdates().flatMap { $0 }.contains { $0.id == newModelID })
    }

    @Test("verified prefetch raises the effective slot cap so old+new can be resident together")
    func verifiedPrefetchRaisesEffectiveSlotCap() async throws {
        let startupModel = ModelInfo(id: "org/startup", sizeBytes: 1, estimatedMemoryGb: 1)
        let newModelID = "org/prefetched-\(UUID().uuidString)"
        let modelDir = try seedSnapshot(modelID: newModelID)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        // Operator default: 3 concurrent slots. A provider that boots advertising
        // ONE model used to freeze its cap at 1 (PR #283 P2 bug) and could not
        // hold a prefetched build alongside the one it serves.
        let loop = try makeLoop(models: [startupModel], maxModelSlots: 3)
        let client = makeClient()
        let coord = ModelPrefetchCoordinator(
            prefetcher: NoopSuccessPrefetcher(),
            preCheck: { _ in .needsFetch },
            onVerified: { id in await loop.applyVerifiedPrefetch(modelId: id) }
        )
        let outbound = OutboundRecorder()
        let capturingSend = SendHandle { outbound.record($0) }
        await loop.installPrefetchCoordinatorForTesting(coord, client: client, send: capturingSend)

        // Before: one model advertised, so the effective cap is 1.
        let beforeCap = await loop.maxModelSlotsForTesting()
        #expect(beforeCap == 1)

        // Fire a prefetch; wait for the new build to become advertised.
        await loop.handlePrefetchModelRequest(modelId: newModelID, priority: 1, send: capturingSend)
        let advertised = await waitUntil(timeout: .seconds(10)) {
            await loop.isModelAdvertised(newModelID)
        }
        #expect(advertised)

        // After: two models advertised, so the effective cap rose to 2 (≤ the
        // configured hard cap of 3) — old and new can be resident concurrently.
        let afterCap = await loop.maxModelSlotsForTesting()
        #expect(afterCap == 2)
        #expect(await loop.advertisedModelCount() == 2)
    }

    @Test("effective slot cap never exceeds the operator-configured hard cap")
    func effectiveSlotCapHonorsHardCap() async throws {
        let startupModel = ModelInfo(id: "org/startup", sizeBytes: 1, estimatedMemoryGb: 1)
        let newModelID = "org/prefetched-\(UUID().uuidString)"
        let modelDir = try seedSnapshot(modelID: newModelID)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        // Operator opted out of concurrency with a hard cap of 1.
        let loop = try makeLoop(models: [startupModel], maxModelSlots: 1)
        let client = makeClient()
        let coord = ModelPrefetchCoordinator(
            prefetcher: NoopSuccessPrefetcher(),
            preCheck: { _ in .needsFetch },
            onVerified: { id in await loop.applyVerifiedPrefetch(modelId: id) }
        )
        let outbound = OutboundRecorder()
        let capturingSend = SendHandle { outbound.record($0) }
        await loop.installPrefetchCoordinatorForTesting(coord, client: client, send: capturingSend)

        #expect(await loop.maxModelSlotsForTesting() == 1)

        await loop.handlePrefetchModelRequest(modelId: newModelID, priority: 1, send: capturingSend)
        let advertised = await waitUntil(timeout: .seconds(10)) {
            await loop.isModelAdvertised(newModelID)
        }
        #expect(advertised)
        // Two models advertised, but the cap stays at 1: the configured hard cap
        // (memory-safety opt-out) is never exceeded.
        #expect(await loop.advertisedModelCount() == 2)
        #expect(await loop.maxModelSlotsForTesting() == 1)
    }

    @Test("prefetch of an already-advertised+hashed model short-circuits to verified")
    func alreadyHashedShortCircuits() async throws {
        let modelID = "org/already-hashed"
        let startup = ModelInfo(id: modelID, sizeBytes: 1, estimatedMemoryGb: 1, weightHash: "abc123")
        // Seed config with a known hash so the pre-check sees a recorded hash.
        let loop = try makeLoopWithHashes(models: [startup], hashes: [modelID: "abc123"])
        let client = makeClient()
        let prefetcher = TrackingPrefetcher()
        let coord = ModelPrefetchCoordinator(
            prefetcher: prefetcher,
            preCheck: { id in await loop.prefetchPreCheckForTesting(id) },
            onVerified: { id in await loop.applyVerifiedPrefetch(modelId: id) }
        )
        await loop.installPrefetchCoordinatorForTesting(coord, client: client)

        let recorder = RecordingPrefetchSink()
        await coord.handlePrefetch(modelId: modelID, priority: 1, sink: recorder)
        let done = await waitUntil(timeout: .seconds(5)) { recorder.terminal() != nil }
        #expect(done)
        #expect(recorder.terminal()?.status == .verified)
        // The prefetcher was NEVER invoked (short-circuit on recorded hash).
        #expect(prefetcher.callCount == 0)
    }

    @Test("desired_models for a build the provider lacks triggers a prefetch of the desired build")
    func desiredModelsTriggersPrefetchOfMissingBuild() async throws {
        // A brand-new provider advertises nothing yet for this alias. It receives
        // a desired_models entry naming a build it does not have on disk; the
        // declarative reconcile must kick off a background prefetch OF THE DESIRED
        // BUILD (not the previous one).
        let desiredBuild = "org/desired-\(UUID().uuidString)"
        let previousBuild = "org/previous-\(UUID().uuidString)"

        let loop = try makeLoop(models: [])
        let client = makeClient()
        // .blockUntilCancelled lets us assert the prefetch STARTED for the desired
        // build without racing a completion; we cancel via shutdown at the end.
        let prefetcher = RecordingBlockingPrefetcher()
        let coord = ModelPrefetchCoordinator(
            prefetcher: prefetcher,
            preCheck: { id in await loop.prefetchPreCheckForTesting(id) },
            onVerified: { id in await loop.applyVerifiedPrefetch(modelId: id) }
        )
        let outbound = OutboundRecorder()
        let capturingSend = SendHandle { outbound.record($0) }
        await loop.installPrefetchCoordinatorForTesting(coord, client: client, send: capturingSend)

        await loop.reconcileDesiredModelsForTesting(
            [CoordinatorMessage.DesiredModelEntry(
                modelName: "alias-a",
                desiredBuild: desiredBuild,
                previousBuild: previousBuild
            )],
            send: capturingSend
        )

        // The desired build's download body started; the previous build was never
        // prefetched (it's only the drop target, not a fetch target).
        let started = await waitUntil(timeout: .seconds(5)) {
            prefetcher.startedIDs.contains(desiredBuild)
        }
        #expect(started)
        #expect(!prefetcher.startedIDs.contains(previousBuild))
        let inflight = await coord.inFlightCount()
        #expect(inflight == 1)

        await coord.shutdown(timeout: .seconds(3))
    }

    @Test("applyVerifiedPrefetch hard-swaps: advertises desired, drops previous from advertisedModels + store, emits models_update")
    func applyVerifiedPrefetchHardSwapsDroppingPrevious() async throws {
        // Seed the on-disk snapshot for the DESIRED build so applyVerifiedPrefetch
        // can scan + hash it. The PREVIOUS build is advertised at startup (loop)
        // and in the client's AdvertisedModelStore, so we can observe the drop.
        let desiredBuild = "org/desired-\(UUID().uuidString)"
        let previousBuild = "org/previous-\(UUID().uuidString)"
        let modelDir = try seedSnapshot(modelID: desiredBuild)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        let previousInfo = ModelInfo(id: previousBuild, sizeBytes: 1, estimatedMemoryGb: 1)
        let loop = try makeLoop(models: [previousInfo], maxModelSlots: 3)
        let client = makeClient()
        // Mirror startup advertising into the client store so the hard-swap drop
        // (unadvertiseModel) has something to remove there too.
        _ = await client.advertiseModel(previousInfo)

        let coord = ModelPrefetchCoordinator(
            prefetcher: NoopSuccessPrefetcher(),
            preCheck: { id in await loop.prefetchPreCheckForTesting(id) },
            onVerified: { id in await loop.applyVerifiedPrefetch(modelId: id) }
        )
        let outbound = OutboundRecorder()
        let capturingSend = SendHandle { outbound.record($0) }
        await loop.installPrefetchCoordinatorForTesting(coord, client: client, send: capturingSend)

        // Before: only the previous build is advertised, on both the loop and the
        // client store.
        #expect(await loop.isModelAdvertised(previousBuild))
        #expect(await client.currentAdvertisedModels().map(\.id).contains(previousBuild))
        #expect(await loop.advertisedModelCount() == 1)

        // Reconcile records previous→desired as the swap target, then prefetches
        // the (missing) desired build. On .verified, applyVerifiedPrefetch fires.
        await loop.reconcileDesiredModelsForTesting(
            [CoordinatorMessage.DesiredModelEntry(
                modelName: "alias-a",
                desiredBuild: desiredBuild,
                previousBuild: previousBuild
            )],
            send: capturingSend
        )

        // Wait for the hard swap to settle: desired advertised, previous dropped.
        let swapped = await waitUntil(timeout: .seconds(10)) {
            let hasDesired = await loop.isModelAdvertised(desiredBuild)
            let hasPrevious = await loop.isModelAdvertised(previousBuild)
            return hasDesired && !hasPrevious
        }
        #expect(swapped)

        // Desired is now the only advertised build on the loop.
        #expect(await loop.isModelAdvertised(desiredBuild))
        #expect(!(await loop.isModelAdvertised(previousBuild)))
        #expect(await loop.advertisedModelCount() == 1)
        // The desired build carries a recorded weight hash (attestation coverage).
        let desiredHash = await loop.modelHashForTesting(desiredBuild)
        #expect(desiredHash != nil && !(desiredHash!.isEmpty))
        // The previous build's hash was forgotten on drop.
        #expect(await loop.modelHashForTesting(previousBuild) == nil)

        // The previous build was also dropped from the client's advertised store
        // (so the next register no longer announces it); desired is now present.
        let clientIDs = await client.currentAdvertisedModels().map(\.id)
        #expect(clientIDs.contains(desiredBuild))
        #expect(!clientIDs.contains(previousBuild))

        // An authoritative models_update was emitted carrying the DESIRED build
        // (with its hash) — this is the wire signal the coordinator uses to derive
        // the previous-build drop from the alias's desired/previous pair.
        let emitted = await waitUntil(timeout: .seconds(5)) {
            outbound.modelsUpdates().contains { models in models.contains { $0.id == desiredBuild } }
        }
        #expect(emitted)
        let desiredUpdate = outbound.modelsUpdates().flatMap { $0 }.first { $0.id == desiredBuild }
        #expect(desiredUpdate?.weightHash == desiredHash)
        // No emitted models_update advertised the previous build as a fresh build.
        #expect(!outbound.modelsUpdates().flatMap { $0 }.contains { $0.id == previousBuild })

        await coord.shutdown(timeout: .seconds(3))
    }

    @Test("desired already converged but previous learned LATE drops previous AND re-emits models_update")
    func reconcileAlreadyConvergedLatePreviousEmitsUpdate() async throws {
        // Models a real sequence: the provider verified the desired build BEFORE
        // any previous build was set on the alias (so the original verify carried
        // no drop). Later the operator sets previous_build; desired_models now
        // names desired (already advertised+hashed) + previous (still advertised).
        // The reconcile must drop previous locally AND re-emit an authoritative
        // models_update for desired — otherwise the coordinator keeps routing the
        // previous build to a provider that has locally stopped serving it.
        let desiredBuild = "org/desired-\(UUID().uuidString)"
        let previousBuild = "org/previous-\(UUID().uuidString)"
        let modelDir = try seedSnapshot(modelID: desiredBuild)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        let previousInfo = ModelInfo(id: previousBuild, sizeBytes: 1, estimatedMemoryGb: 1)
        let loop = try makeLoop(models: [previousInfo], maxModelSlots: 3)
        let client = makeClient()
        _ = await client.advertiseModel(previousInfo)

        let coord = ModelPrefetchCoordinator(
            prefetcher: NoopSuccessPrefetcher(),
            preCheck: { id in await loop.prefetchPreCheckForTesting(id) },
            onVerified: { id in await loop.applyVerifiedPrefetch(modelId: id) }
        )
        let outbound = OutboundRecorder()
        let capturingSend = SendHandle { outbound.record($0) }
        await loop.installPrefetchCoordinatorForTesting(coord, client: client, send: capturingSend)

        // Step 1: converge desired with NO previous on the alias yet — verify it.
        await loop.reconcileDesiredModelsForTesting(
            [CoordinatorMessage.DesiredModelEntry(modelName: "alias-a", desiredBuild: desiredBuild)],
            send: capturingSend
        )
        let converged = await waitUntil(timeout: .seconds(10)) {
            let hasDesired = await loop.isModelAdvertised(desiredBuild)
            let hashed = await loop.modelHashForTesting(desiredBuild) != nil
            return hasDesired && hashed
        }
        #expect(converged)
        // Previous is still advertised (no drop happened — it wasn't in the alias).
        #expect(await loop.isModelAdvertised(previousBuild))
        let updatesAfterConverge = outbound.modelsUpdates().count

        // Step 2: the operator sets previous_build; desired_models now carries it.
        // Desired is already advertised+hashed, so we hit the already-converged path.
        await loop.reconcileDesiredModelsForTesting(
            [CoordinatorMessage.DesiredModelEntry(
                modelName: "alias-a",
                desiredBuild: desiredBuild,
                previousBuild: previousBuild
            )],
            send: capturingSend
        )

        // Previous is dropped locally AND from the client store.
        let dropped = await waitUntil(timeout: .seconds(5)) {
            !(await loop.isModelAdvertised(previousBuild))
        }
        #expect(dropped)
        #expect(!(await client.currentAdvertisedModels().map(\.id).contains(previousBuild)))
        #expect(await loop.isModelAdvertised(desiredBuild))

        // A FRESH models_update for the desired build was emitted on the
        // already-converged path (so the coordinator derives the previous drop).
        let emittedFresh = await waitUntil(timeout: .seconds(5)) {
            outbound.modelsUpdates().count > updatesAfterConverge
        }
        #expect(emittedFresh)
        let latest = outbound.modelsUpdates().suffix(from: updatesAfterConverge).flatMap { $0 }
        #expect(latest.contains { $0.id == desiredBuild })
        #expect(!latest.contains { $0.id == previousBuild })

        await coord.shutdown(timeout: .seconds(3))
    }

    @Test("late verify for stale desired build is ignored after alias retarget")
    func staleDesiredPrefetchVerifyIsIgnoredAfterRetarget() async throws {
        let staleDesired = "org/stale-\(UUID().uuidString)"
        let currentBuild = "org/current-\(UUID().uuidString)"
        let newDesired = "org/new-\(UUID().uuidString)"
        let staleDir = try seedSnapshot(modelID: staleDesired)
        defer { try? FileManager.default.removeItem(at: staleDir) }

        let currentInfo = ModelInfo(id: currentBuild, sizeBytes: 1, estimatedMemoryGb: 1)
        let loop = try makeLoop(models: [currentInfo], maxModelSlots: 3)
        let client = makeClient()
        _ = await client.advertiseModel(currentInfo)

        let prefetcher = RecordingBlockingPrefetcher()
        let coord = ModelPrefetchCoordinator(
            prefetcher: prefetcher,
            preCheck: { id in await loop.prefetchPreCheckForTesting(id) },
            onVerified: { id in await loop.applyVerifiedPrefetch(modelId: id) }
        )
        let outbound = OutboundRecorder()
        let capturingSend = SendHandle { outbound.record($0) }
        await loop.installPrefetchCoordinatorForTesting(coord, client: client, send: capturingSend)

        await loop.reconcileDesiredModelsForTesting(
            [CoordinatorMessage.DesiredModelEntry(
                modelName: "alias-a",
                desiredBuild: staleDesired,
                previousBuild: currentBuild
            )],
            send: capturingSend
        )
        let staleStarted = await waitUntil(timeout: .seconds(5)) {
            prefetcher.startedIDs.contains(staleDesired)
        }
        #expect(staleStarted)

        await loop.reconcileDesiredModelsForTesting(
            [CoordinatorMessage.DesiredModelEntry(
                modelName: "alias-a",
                desiredBuild: newDesired,
                previousBuild: currentBuild
            )],
            send: capturingSend
        )

        await loop.applyVerifiedPrefetch(modelId: staleDesired)

        #expect(!(await loop.isModelAdvertised(staleDesired)))
        #expect(await loop.isModelAdvertised(currentBuild))
        #expect(await client.currentAdvertisedModels().map(\.id).contains(currentBuild))
        #expect(!outbound.modelsUpdates().flatMap { $0 }.contains { $0.id == staleDesired })

        await coord.shutdown(timeout: .seconds(3))
    }

    /// Seed a snapshot with config.json but NO weight files. scanVerifiedModelInfo
    /// returns nil (parseModelInfo requires sizeBytes > 0) — the same guard the
    /// nil-weight-hash case falls into: a verify that can't produce a hashed,
    /// advertisable build. Used to prove neither path strands the previous build.
    private func seedConfigOnlySnapshot(modelID: String) throws -> URL {
        let snapshot = ModelDownloader.cacheSnapshotDirectory(for: modelID)
        let modelDir = ModelDownloader.cacheModelDirectory(for: modelID)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let refs = modelDir.appendingPathComponent("refs", isDirectory: true)
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        try Data(#"{"model_type":"qwen3"}"#.utf8).write(to: snapshot.appendingPathComponent("config.json"))
        try "local".write(to: refs.appendingPathComponent("main"), atomically: true, encoding: .utf8)
        return modelDir
    }

    @Test("a verify that can't produce an advertisable+hashed build keeps the previous build (no strand)")
    func verifiedPrefetchUnhashableKeepsPrevious() async throws {
        // A verify whose snapshot yields no advertisable+hashed ModelInfo (here:
        // no weight files, so scanVerifiedModelInfo returns nil — the same early
        // return the nil-weight-hash guard takes) must NOT advertise/emit the
        // build AND must leave the previous build untouched. Dropping previous
        // here while the build can't be advertised would strand the provider on
        // neither — the coordinator's models_update gate would also reject a
        // hashless build, so the local drop must not run ahead of a real swap.
        let desiredBuild = "org/unhashable-\(UUID().uuidString)"
        let previousBuild = "org/previous-\(UUID().uuidString)"
        let modelDir = try seedConfigOnlySnapshot(modelID: desiredBuild)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        let previousInfo = ModelInfo(id: previousBuild, sizeBytes: 1, estimatedMemoryGb: 1)
        let loop = try makeLoop(models: [previousInfo], maxModelSlots: 3)
        let client = makeClient()
        _ = await client.advertiseModel(previousInfo)

        let verifiedCalls = AdvertisedRecorder()
        let coord = ModelPrefetchCoordinator(
            prefetcher: NoopSuccessPrefetcher(),
            preCheck: { id in await loop.prefetchPreCheckForTesting(id) },
            onVerified: { id in
                await loop.applyVerifiedPrefetch(modelId: id)
                verifiedCalls.record(id)
            }
        )
        let outbound = OutboundRecorder()
        let capturingSend = SendHandle { outbound.record($0) }
        await loop.installPrefetchCoordinatorForTesting(coord, client: client, send: capturingSend)

        await loop.reconcileDesiredModelsForTesting(
            [CoordinatorMessage.DesiredModelEntry(
                modelName: "alias-a",
                desiredBuild: desiredBuild,
                previousBuild: previousBuild
            )],
            send: capturingSend
        )

        // Wait until applyVerifiedPrefetch has fully run.
        let ran = await waitUntil(timeout: .seconds(10)) { verifiedCalls.ids.contains(desiredBuild) }
        #expect(ran)

        // The hashless desired build is NOT advertised anywhere, and no
        // models_update was emitted for it.
        #expect(!(await loop.isModelAdvertised(desiredBuild)))
        #expect(await loop.modelHashForTesting(desiredBuild) == nil)
        #expect(!(await client.currentAdvertisedModels().map(\.id).contains(desiredBuild)))
        #expect(!outbound.modelsUpdates().flatMap { $0 }.contains { $0.id == desiredBuild })
        // The previous build is UNTOUCHED — still serving (no unverifiable swap).
        #expect(await loop.isModelAdvertised(previousBuild))
        #expect(await client.currentAdvertisedModels().map(\.id).contains(previousBuild))

        await coord.shutdown(timeout: .seconds(3))
    }

    @Test("a failed desired-build prefetch retries with bounded backoff, and a fresh push resets the budget")
    func failedDesiredPrefetchSchedulesBoundedRetries() async throws {
        // One transient download failure must not strand the provider on the old
        // build: each failure of a still-desired build schedules one retry per
        // configured delay, then gives up until the next desired_models push.
        let desiredBuild = "org/desired-\(UUID().uuidString)"

        let loop = try makeLoop(models: [])
        let client = makeClient()
        let prefetcher = FailingCountingPrefetcher()
        let coord = ModelPrefetchCoordinator(
            prefetcher: prefetcher,
            preCheck: { id in await loop.prefetchPreCheckForTesting(id) },
            onVerified: { id in await loop.applyVerifiedPrefetch(modelId: id) }
        )
        let outbound = OutboundRecorder()
        let capturingSend = SendHandle { outbound.record($0) }
        await loop.installPrefetchCoordinatorForTesting(coord, client: client, send: capturingSend)
        await loop.setDesiredPrefetchRetryDelaysForTesting([.milliseconds(20), .milliseconds(20)])

        let entry = CoordinatorMessage.DesiredModelEntry(
            modelName: "alias-a", desiredBuild: desiredBuild, previousBuild: nil
        )
        await loop.reconcileDesiredModelsForTesting([entry], send: capturingSend)

        // Initial attempt + exactly 2 retries (the delay budget), then no more.
        let exhausted = await waitUntil(timeout: .seconds(5)) { prefetcher.count(for: desiredBuild) == 3 }
        #expect(exhausted)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(prefetcher.count(for: desiredBuild) == 3)
        #expect(await loop.pendingDesiredPrefetchRetriesForTesting() == 0)

        // A fresh declarative push resets the budget: one immediate reconcile
        // attempt plus two more retries.
        await loop.reconcileDesiredModelsForTesting([entry], send: capturingSend)
        let resumed = await waitUntil(timeout: .seconds(5)) { prefetcher.count(for: desiredBuild) == 6 }
        #expect(resumed)

        await coord.shutdown(timeout: .seconds(3))
    }

    @Test("a pending prefetch retry is cancelled when the build leaves the desired set")
    func failedDesiredPrefetchRetryStopsAfterRetarget() async throws {
        let oldDesired = "org/old-desired-\(UUID().uuidString)"
        let newDesired = "org/new-desired-\(UUID().uuidString)"

        let loop = try makeLoop(models: [])
        let client = makeClient()
        let prefetcher = FailingCountingPrefetcher()
        let coord = ModelPrefetchCoordinator(
            prefetcher: prefetcher,
            preCheck: { id in await loop.prefetchPreCheckForTesting(id) },
            onVerified: { id in await loop.applyVerifiedPrefetch(modelId: id) }
        )
        let outbound = OutboundRecorder()
        let capturingSend = SendHandle { outbound.record($0) }
        await loop.installPrefetchCoordinatorForTesting(coord, client: client, send: capturingSend)
        // Long enough that the retarget below reliably lands inside the backoff.
        await loop.setDesiredPrefetchRetryDelaysForTesting([.milliseconds(300)])

        await loop.reconcileDesiredModelsForTesting(
            [CoordinatorMessage.DesiredModelEntry(
                modelName: "alias-a", desiredBuild: oldDesired, previousBuild: nil
            )],
            send: capturingSend
        )
        // First attempt failed and a retry timer is pending.
        let scheduled = await waitUntil(timeout: .seconds(5)) {
            if prefetcher.count(for: oldDesired) != 1 { return false }
            return await loop.pendingDesiredPrefetchRetriesForTesting() == 1
        }
        #expect(scheduled)

        // Operator retargets the alias before the retry fires: the pending retry
        // for the stale build is cancelled.
        await loop.reconcileDesiredModelsForTesting(
            [CoordinatorMessage.DesiredModelEntry(
                modelName: "alias-a", desiredBuild: newDesired, previousBuild: nil
            )],
            send: capturingSend
        )
        try? await Task.sleep(for: .milliseconds(500))
        #expect(prefetcher.count(for: oldDesired) == 1)

        await coord.shutdown(timeout: .seconds(3))
    }

    private func makeLoopWithHashes(models: [ModelInfo], hashes: [String: String]) throws -> ProviderLoop {
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546
            ),
            models: models,
            config: ProviderConfig(
                provider: ProviderSettings(name: "prefetch-unit-test", memoryReserveGB: 1),
                backend: BackendSettings(continuousBatching: true, idleTimeoutMins: 0, maxModelSlots: 2),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
            ),
            modelHashes: hashes
        )
        return try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
    }
}

/// Prefetcher that always fails, counting attempts per model id — drives the
/// desired-build retry policy tests.
private final class FailingCountingPrefetcher: ModelPrefetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func count(for modelID: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[modelID] ?? 0
    }
    func prefetchToDisk(
        modelID: String,
        onByteProgress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws {
        lock.withLock { counts[modelID, default: 0] += 1 }
        throw ModelCatalogError.downloadFailed("simulated transient network failure")
    }
}

/// Prefetcher that records whether it was actually invoked (asserts the
/// short-circuit path never calls it).
private final class TrackingPrefetcher: ModelPrefetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _count }
    func prefetchToDisk(
        modelID: String,
        onByteProgress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws {
        lock.withLock { _count += 1 }
    }
}

/// Prefetcher that records every model id whose download body STARTED and then
/// blocks forever (until task cancellation). Lets a reconcile test assert which
/// build a `desired_models` entry actually triggered a fetch for, without racing
/// a completion.
private final class RecordingBlockingPrefetcher: ModelPrefetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _startedIDs: [String] = []
    var startedIDs: [String] { lock.lock(); defer { lock.unlock() }; return _startedIDs }
    func prefetchToDisk(
        modelID: String,
        onByteProgress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws {
        lock.withLock { _startedIDs.append(modelID) }
        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Minimal sink for the short-circuit test.
private final class RecordingPrefetchSink: PrefetchStatusSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [(ProviderMessage.PrefetchModelStatus.Status, String?)] = []
    func emit(modelId: String, status: ProviderMessage.PrefetchModelStatus.Status, bytesDone: Int64, bytesTotal: Int64, error: String?) {
        lock.withLock { _events.append((status, error)) }
    }
    func terminal() -> (status: ProviderMessage.PrefetchModelStatus.Status, error: String?)? {
        lock.withLock { _events.last(where: { $0.0 == .verified || $0.0 == .failed }) }
    }
}
