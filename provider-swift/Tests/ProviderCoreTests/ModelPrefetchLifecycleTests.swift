import Foundation
import Testing

@testable import ProviderCore

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

        _ = await sink.waitForTerminal()

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
        _ = await sink.waitForTerminal()

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
        _ = await sink.waitForTerminal()

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

    @Test("shutdown completes when its injected deadline wins a parked task")
    func shutdownUsesDeadlineLatch() async {
        let prefetcher = FakePrefetcher(.success(total: 10, steps: 1))
        let verifyEntered = AsyncTestLatch()
        let verifyRelease = AsyncTestLatch()
        let verifyExited = AsyncTestLatch()
        let sleeper = ControlledTestSleeper()
        let coord = ModelPrefetchCoordinator(
            prefetcher: prefetcher,
            preCheck: { _ in .needsFetch },
            onVerified: { _ in
                verifyEntered.signal()
                await verifyRelease.wait()
                verifyExited.signal()
            },
            shutdownSleep: { duration in try await sleeper.sleep(duration) }
        )
        let sink = RecordingSink()
        await coord.handlePrefetch(modelId: "org/stuck", priority: 1, sink: sink)
        await verifyEntered.wait()

        let shutdown = Task { await coord.shutdown(timeout: .seconds(10)) }
        await sleeper.waitForRequest()
        sleeper.resumeNext()
        await shutdown.value

        #expect(sink.terminal() == nil)
        #expect(await coord.inFlightCount() == 0)
        verifyRelease.signal()
        await verifyExited.wait()
    }
}
