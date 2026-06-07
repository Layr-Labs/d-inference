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

/// One-shot async semaphore for coordinating test timing.
private final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            signalled = true
            let p = waiters
            waiters.removeAll()
            return p
        }
        for w in pending { w.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if signalled { return true }
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

    private func makeLoop(models: [ModelInfo]) throws -> ProviderLoop {
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
        await loop.installPrefetchCoordinatorForTesting(coord, client: client)

        // Before: only the startup model is advertised.
        let beforeCount = await loop.advertisedModelCount()
        #expect(beforeCount == 1)
        let newAdvertisedBefore = await loop.isModelAdvertised(newModelID)
        #expect(!newAdvertisedBefore)

        // Fire a prefetch via the real handler.
        let sink = RecordingSink()
        await loop.handlePrefetchModelRequest(modelId: newModelID, priority: 1, send: SendHandle { _ in })
        _ = sink

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
