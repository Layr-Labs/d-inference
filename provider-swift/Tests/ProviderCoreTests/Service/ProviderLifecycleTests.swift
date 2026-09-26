import Foundation
import Testing
@testable import ProviderCore

private func lifecycleLoop() async throws -> (ProviderLoop, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let hardware = HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4,
        chipTier: .max, memoryGb: 128, memoryAvailableGb: 124,
        cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4), gpuCores: 40, memoryBandwidthGbs: 546)
    let loop = try ProviderLoop(config: ProviderLoopConfig(coordinatorURL: "ws://127.0.0.1:0/unused",
        hardware: hardware, models: [], config: ProviderConfig(provider: ProviderSettings(name: "lifecycle-test"))), purgeLegacyFiles: false, attestationSigner: nil)
    await loop.setDaemonStateFileForTesting(root.appendingPathComponent("state.json"))
    return (loop, root)
}

private extension ProviderLoop {
    func holdLifecycleRequests(_ ids: Set<String>) { acceptedLifecycleRequests.formUnion(ids) }
    func completeLifecycleRequest(_ id: String) { acceptedLifecycleRequests.remove(id) }
    func installCancellableLifecycleRequest(_ id: String) {
        acceptedLifecycleRequests.insert(id)
        inflightTasks[id] = Task {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            // In production this occurs only after the terminal was queued.
            self.acceptedLifecycleRequests.remove(id)
        }
    }
}

@Suite("Provider lifecycle drain")
struct ProviderLifecycleTests {
    @Test func concurrentAcceptedWorkAndLocalResponsesFinishBeforeDrain() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.holdLifecycleRequests(["stream-model-a", "nonstream-model-b", "accepted-cold-load"])
        let tracker = await loop.localResponseTracker
        let lease = try tracker.admit()
        let identity = try #require(ProcessIdentity.current())
        let task = Task { await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 3)) }
        for _ in 0..<100 {
            if await loop.servingDrain.refusing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await loop.state.refusingNewWork)
        #expect(throws: (any Error).self) { try tracker.admit() }
        await #expect(throws: (any Error).self) { try await loop.throwIfRefusingNewLocalWork() }
        for id in ["stream-model-a", "nonstream-model-b", "accepted-cold-load"] { await loop.completeLifecycleRequest(id) }
        #expect(await loop.lifecycleRemaining == 1)
        #expect(await loop.lifecycleStatus.outcome == .draining)
        lease.release()
        let result = await task.value
        #expect(result.outcome == .drained)
        #expect(result.remaining == 0)
        #expect(await loop.servingDrain.phase == .drained)
    }

    @Test func timeoutDoesNotCancelAcceptedWorkAndRetryCanFinish() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.holdLifecycleRequests(["stalled"])
        let identity = try #require(ProcessIdentity.current())
        let result = await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 0))
        #expect(result.outcome == .timedOut)
        #expect(result.remaining == 1)
        #expect(await loop.servingDrain.refusing)
        await loop.completeLifecycleRequest("stalled")
        let retried = await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 1))
        #expect(retried.outcome == .drained)
    }

    @Test func forceCancelsOwnedWorkButWaitsForTerminalCleanup() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.installCancellableLifecycleRequest("forced")
        let result = await loop.drainForLifecycle(request: .init(target: try #require(ProcessIdentity.current()), timeoutSeconds: 0, force: true))
        #expect(result.outcome == .forced)
        #expect(result.remaining == 0)
    }

    @Test func interruptedCallerDoesNotCancelDrainOrReopenAdmission() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.holdLifecycleRequests(["accepted"])
        let identity = try #require(ProcessIdentity.current())
        let task = Task { await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 2)) }
        task.cancel()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(await loop.lifecycleRemaining == 1)
        await loop.completeLifecycleRequest("accepted")
        #expect(await task.value.outcome == .drained)
    }

    @Test func forceCanReplaceAnExistingWaitWithoutLosingOwnership() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.installCancellableLifecycleRequest("stalled")
        let identity = try #require(ProcessIdentity.current())
        let first = Task { await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 5)) }
        for _ in 0..<100 {
            if await loop.servingDrain.refusing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await loop.lifecycleRemaining == 1)
        let forced = await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 0, force: true))
        #expect(forced.outcome == .forced)
        #expect(forced.remaining == 0)
        #expect(await first.value.outcome == .timedOut)
    }

    @Test func failedUpdateCannotResumeLifecycleOwnedAdmission() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        await loop.beginUpdateDraining()
        _ = await loop.drainForLifecycle(request: .init(target: try #require(ProcessIdentity.current()), timeoutSeconds: 1))
        await loop.resumeServingAfterUpdate()
        #expect(await loop.state.refusingNewWork)
        #expect(await loop.servingDrain.refusing)
    }

    @Test func lifecycleDrainTakesOwnershipFromAnAppAttestStallRestart() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await !loop.appAttestStallRestartOwnsDrain)
        await loop.beginUpdateDraining()
        #expect(await loop.appAttestStallRestartOwnsDrain)
        await loop.holdLifecycleRequests(["accepted"])
        let identity = try #require(ProcessIdentity.current())
        let stop = Task { await loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 2)) }
        for _ in 0..<100 {
            if await loop.servingDrain.owner == .lifecycle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await !loop.appAttestStallRestartOwnsDrain)
        await loop.completeLifecycleRequest("accepted")
        #expect(await stop.value.outcome == .drained)
        // The finished stop keeps ownership: the stall path must not restart.
        #expect(await !loop.appAttestStallRestartOwnsDrain)
    }

    @Test func abandonedAppAttestStallRestartReopensServingAndDefersTheNextDrain() async throws {
        let (loop, root) = try await lifecycleLoop()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await !loop.appAttestStallRetryDeferred)
        await loop.beginUpdateDraining()
        #expect(await loop.servingDrain.refusing)
        await loop.abandonAppAttestStallRestart(after: .markerNotPersisted)
        // Serving reopens at once, but the monitor may not drain again on its next tick.
        #expect(await !loop.servingDrain.refusing)
        #expect(await loop.updatePhase == .idle)
        #expect(await loop.appAttestStallRetryDeferred)
    }
}
