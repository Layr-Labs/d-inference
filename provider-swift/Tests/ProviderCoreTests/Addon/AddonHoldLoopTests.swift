import Darwin
import Foundation
import Testing

@testable import ProviderCore

/// A settable wall clock for leases (milliseconds).
final class AddonTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var milliseconds: Int64
    init(_ start: Int64 = 1_800_000_000_000) { milliseconds = start }
    var now: Int64 { lock.withLock { milliseconds } }
    func advance(seconds: Int64) { lock.withLock { milliseconds += seconds * 1_000 } }
}

final class AddonOutboundRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [OutboundMessage] = []
    func append(_ message: OutboundMessage) { lock.withLock { messages.append(message) } }
    var prefetchFailures: [String] {
        lock.withLock {
            messages.compactMap { if case .prefetchModelStatus(let id, .failed, _, _, _) = $0 { return id }; return nil }
        }
    }
}

extension ProviderLoop {
    /// `serving: false` gives persistence and the lock without a socket, for
    /// loops that never call `run()`; `run()` starts the service otherwise.
    func useAddonHoldForTesting(paths: AddonHoldPaths?, clock: AddonTestClock,
                                authenticate: AddonIPCServer.Authenticate? = nil, serving: Bool = false) {
        addonHoldPathsOverride = paths
        if !serving { addonHoldPaths = paths }
        addonHoldNowMs = { clock.now }
        addonPeerAuthenticatorOverride = authenticate
    }
    func setAddonHoldDrainTimeoutForTesting(_ timeout: Duration) { addonHoldDrainTimeout = timeout }
    func setAddonHoldSettleTimeoutForTesting(_ timeout: Duration) { addonHoldSettleTimeout = timeout }
    func setAddonHoldStragglerHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        addonHoldBeforeCancellingStragglersForTesting = hook
    }
    /// A running coordinator request that only cancellation ends.
    func startAddonTestRequest(_ id: String) {
        acceptedLifecycleRequests.insert(id)
        inflightTasks[id] = Task {
            try? await Task.sleep(for: .seconds(3_600))
            self.acceptedLifecycleRequests.remove(id)
        }
    }
    func addonTestRequestIsRunning(_ id: String) -> Bool {
        inflightTasks[id] != nil && acceptedLifecycleRequests.contains(id)
    }
    func cancelAddonTestRequests() {
        for task in inflightTasks.values { task.cancel() }
        inflightTasks.removeAll()
    }
    func restartAddonHoldServiceForTesting() {
        stopAddonHoldService()
        addonHoldPaths = nil
        startAddonHoldService()
    }
    func addonHoldsForTesting() -> [AddonHold] { addonHolds.sorted }
    func acceptAddonTestRequest(_ id: String) { acceptedLifecycleRequests.insert(id) }
    func finishAddonTestRequest(_ id: String) { acceptedLifecycleRequests.remove(id) }
    func setAddonTestOutbound(_ send: SendHandle) { outboundSend = send }
    func addonHoldDrainOwner() -> ProviderDrain.Owner? { servingDrain.owner }
}

@Suite("Add-on hold provider loop", .serialized)
struct AddonHoldLoopTests {
    static let addon = "io.darkbloom.sandbox"
    static let peer = AddonPeer(identifier: addon)

    struct Harness {
        let loop: ProviderLoop
        let sandbox: ModelLoadingSandbox
        let runtime: AddonRuntimeFixture
        let clock: AddonTestClock

        func remove() {
            sandbox.remove()
            runtime.remove()
        }

        func hold(lease: Int = 60, vmBytes: UInt64 = 8 << 30, peer: AddonPeer = AddonHoldLoopTests.peer) async -> AddonIPC.Response {
            await loop.handleAddonIPC(.hold(addon: peer.identifier, vmBytes: vmBytes, leaseSeconds: lease), peer: peer)
        }

        func status(_ id: String, peer: AddonPeer = AddonHoldLoopTests.peer) async -> AddonIPC.Response {
            await loop.handleAddonIPC(.status(holdID: id), peer: peer)
        }

        func awaitState(_ id: String, _ expected: AddonIPC.HoldState) async throws {
            let held = try await addonEventually {
                if case .status(let state, _, _) = await status(id) { return state == expected }
                return false
            }
            try #require(held, "hold \(id) never reached \(expected)")
        }
    }

    private func harness(persistence: Bool = true) async throws -> Harness {
        let sandbox = try ModelLoadingSandbox()
        let runtime = try AddonRuntimeFixture()
        let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)
        let clock = AddonTestClock()
        await loop.useAddonHoldForTesting(paths: persistence ? runtime.paths : nil, clock: clock)
        return Harness(loop: loop, sandbox: sandbox, runtime: runtime, clock: clock)
    }

    private static func holdID(_ response: AddonIPC.Response) throws -> String {
        guard case .hold(let id, _, _, _) = response else {
            Issue.record("expected a hold, got \(response)")
            throw CancellationError()
        }
        return id
    }

    @Test func holdClosesAdmissionUnloadsEveryModelAndKeepsTheServingSet() async throws {
        let h = try await harness()
        defer { h.remove() }
        await h.loop.setLoadedModelsFileForTesting(h.sandbox.loadedModelsFile)
        let first = makeInertStubBridge(modelId: "test/held-a")
        let second = makeInertStubBridge(modelId: "test/held-b")
        await h.loop.modelLoadingInstallSlot("test/held-a", bridge: first.bridge)
        await h.loop.modelLoadingInstallSlot("test/held-b", bridge: second.bridge)
        await h.loop.persistLoadedModelSetForTesting()

        let response = await h.hold()
        guard case .hold(let id, .draining, let since, let expires) = response else {
            Issue.record("expected a draining hold, got \(response)")
            return
        }
        #expect(since == h.clock.now && expires == since + 60_000)
        #expect(await h.loop.state.refusingNewWork)
        #expect(await h.loop.state.busy == ProviderBusy(reason: .addon, sinceMs: since, addon: Self.addon))
        await #expect(throws: (any Error).self) { try await h.loop.throwIfRefusingNewLocalWork() }
        let reasons = await h.loop.autopilotBusyReasons()
        #expect(reasons.first == .addonHold && !reasons.contains(.draining))

        try await h.awaitState(id, .held)
        #expect(await h.loop.modelLoadingResidentIDs().isEmpty)
        #expect(first.engine.shutdownCalls == 1 && second.engine.shutdownCalls == 1)
        // The temporary unload keeps the next start's preload plan.
        #expect(LoadedModelsStore.read(from: h.sandbox.loadedModelsFile) == ["test/held-a", "test/held-b"])
        #expect(AddonHoldStore(url: h.runtime.paths.holdState).read()
            == .holds(await h.loop.addonHoldsForTesting()))
        #expect(await h.loop.addonHoldsForTesting().map(\.state) == [.held])
        #expect(await h.loop.currentDaemonState().addonHold?.holds.map(\.state) == ["held"])
        // No stop or update owns admission, and the App Attest worker is untouched.
        #expect(await h.loop.addonHoldDrainOwner() == .addonHold)
        #expect(await !h.loop.appAttestWorkerStopped)
    }

    @Test func holdIsIdempotentPerAddonAndOnlyItsSignerCanUseIt() async throws {
        let h = try await harness()
        defer { h.remove() }
        let id = try Self.holdID(await h.hold(lease: 60))
        h.clock.advance(seconds: 10)
        guard case .hold(let again, _, let since, let expires) = await h.hold(lease: 120, vmBytes: 1) else {
            Issue.record("repeat hold failed")
            return
        }
        #expect(again == id && expires == h.clock.now + 120_000 && since == h.clock.now - 10_000)
        #expect(await h.loop.addonHoldsForTesting().map(\.vmBytes) == [1])
        try await h.awaitState(id, .held)
        h.clock.advance(seconds: 5)
        #expect(await h.loop.handleAddonIPC(.renew(holdID: id, leaseSeconds: 300), peer: Self.peer)
            == .renewed(state: .held, leaseExpiresAtMs: h.clock.now + 300_000))
        #expect(await h.loop.addonHoldsForTesting().map(\.holdID) == [id])

        let other = AddonPeer(identifier: "io.example.other")
        #expect(await h.loop.handleAddonIPC(.hold(addon: Self.addon, vmBytes: 0, leaseSeconds: 60), peer: other)
            == .failure(.unauthorized))
        #expect(await h.status(id, peer: other) == .failure(.notFound))
        #expect(await h.loop.handleAddonIPC(.release(holdID: id), peer: other) == .failure(.notFound))
        #expect(await h.status("unknown") == .failure(.notFound))
        #expect(await h.loop.handleAddonIPC(.hello, peer: Self.peer) == .hello(providerVersion: ProviderCore.version))
    }

    @Test func releaseReopensAdmissionAndReplaysDeferredDesiredModels() async throws {
        let h = try await harness()
        defer { h.remove() }
        let recorder = AddonOutboundRecorder()
        let send = SendHandle { recorder.append($0) }
        await h.loop.setAddonTestOutbound(send)
        let id = try Self.holdID(await h.hold())
        try await h.awaitState(id, .held)
        let desired = CoordinatorMessage.DesiredModelEntry(modelName: "alias", desiredBuild: "org/desired-build")
        await h.loop.handleDesiredModels([desired], send: send)
        #expect(await h.loop.deferredDesiredModels == [desired])
        #expect(recorder.prefetchFailures.isEmpty)

        #expect(await h.loop.handleAddonIPC(.release(holdID: id), peer: Self.peer) == .released)
        #expect(await !h.loop.state.refusingNewWork)
        #expect(await h.loop.state.busy == nil)
        #expect(await h.loop.addonHoldDrainOwner() == nil)
        try await h.loop.throwIfRefusingNewLocalWork()
        #expect(try await addonEventually { recorder.prefetchFailures == ["org/desired-build"] })
        #expect(await h.loop.deferredDesiredModels == nil)
        #expect(await h.loop.autopilotBusyReasons().isEmpty)
        #expect(AddonHoldStore(url: h.runtime.paths.holdState).read() == .absent)
        // A late status, renew or release of the ended hold gets a definite answer.
        #expect(await h.status(id) == .status(state: .released, sinceMs: h.clock.now, leaseExpiresAtMs: h.clock.now + 60_000))
        #expect(await h.loop.handleAddonIPC(.release(holdID: id), peer: Self.peer) == .released)
        #expect(await h.loop.handleAddonIPC(.renew(holdID: id, leaseSeconds: 60), peer: Self.peer)
            == .renewed(state: .released, leaseExpiresAtMs: h.clock.now + 60_000))
    }

    @Test func acceptedWorkFinishesFirstAndTheBoundCancelsTheRest() async throws {
        let h = try await harness()
        defer { h.remove() }
        await h.loop.acceptAddonTestRequest("accepted")
        let id = try Self.holdID(await h.hold())
        try await Task.sleep(for: .milliseconds(300))
        #expect(await h.status(id) == .status(state: .draining, sinceMs: h.clock.now, leaseExpiresAtMs: h.clock.now + 60_000))
        await h.loop.finishAddonTestRequest("accepted")
        try await h.awaitState(id, .held)
        #expect(await h.loop.handleAddonIPC(.release(holdID: id), peer: Self.peer) == .released)

        await h.loop.setAddonHoldDrainTimeoutForTesting(.milliseconds(200))
        await h.loop.acceptAddonTestRequest("stalled")
        let bounded = try Self.holdID(await h.hold())
        try await h.awaitState(bounded, .held)
    }

    @Test func theDrainBoundCancelsItsStragglersButNeverWorkAcceptedAfterARelease() async throws {
        let h = try await harness()
        defer { h.remove() }
        await h.loop.setAddonHoldDrainTimeoutForTesting(.milliseconds(100))
        // A coordinator request that outlives the bound is cancelled.
        await h.loop.startAddonTestRequest("stalled")
        let first = try Self.holdID(await h.hold())
        try await h.awaitState(first, .held)
        #expect(await !h.loop.addonTestRequestIsRunning("stalled"))
        #expect(await h.loop.handleAddonIPC(.release(holdID: first), peer: Self.peer) == .released)

        // The hold is released while its cancellation pass is suspended, and
        // admission reopens. Work accepted after the release, and work the
        // released hold no longer needs to stop, keeps running and tracked.
        let pass = UpgradeBarrier()
        await h.loop.setAddonHoldStragglerHookForTesting { await pass.wait() }
        await h.loop.startAddonTestRequest("before-hold")
        let second = try Self.holdID(await h.hold())
        await pass.observeEntry()
        #expect(await h.loop.handleAddonIPC(.release(holdID: second), peer: Self.peer) == .released)
        #expect(await !h.loop.state.refusingNewWork)
        await h.loop.startAddonTestRequest("after-release")
        await pass.release()
        let disturbed = try await addonEventually(timeout: .seconds(1)) {
            await !h.loop.addonTestRequestIsRunning("after-release")
        }
        #expect(!disturbed, "the released hold's cancellation pass cancelled work accepted after the release")
        #expect(await h.loop.addonTestRequestIsRunning("before-hold"))
        await h.loop.cancelAddonTestRequests()
    }

    @Test func updateDrainAndReconnectCannotReopenAHold() async throws {
        let h = try await harness()
        defer { h.remove() }
        let id = try Self.holdID(await h.hold())
        try await h.awaitState(id, .held)
        await h.loop.beginUpdateDraining()
        #expect(await h.loop.addonHoldDrainOwner() == .addonHold)
        await h.loop.resumeServingAfterUpdate()
        #expect(await h.loop.addonHoldDrainOwner() == .addonHold)
        #expect(await h.loop.state.refusingNewWork)
        // A fresh registration (`.connected`) keeps the hold and its busy fields.
        await h.loop.finishPlannedReconnect()
        #expect(await h.loop.addonHoldDrainOwner() == .addonHold)
        #expect(await h.loop.state.refusingNewWork)
        #expect(await h.loop.state.busy?.addon == Self.addon)
        await #expect(throws: (any Error).self) { try await h.loop.throwIfRefusingNewLocalWork() }
        #expect(await h.loop.handleAddonIPC(.release(holdID: id), peer: Self.peer) == .released)
        #expect(await !h.loop.state.refusingNewWork)
    }

    @Test func aStopTakesOverAndNoNewHoldIsAcceptedWhileStopping() async throws {
        let h = try await harness()
        defer { h.remove() }
        let id = try Self.holdID(await h.hold())
        try await h.awaitState(id, .held)
        let identity = try #require(ProcessIdentity.current())
        _ = await h.loop.drainForLifecycle(request: .init(target: identity, timeoutSeconds: 1))
        #expect(await h.loop.addonHoldDrainOwner() == .lifecycle)
        // The record stays so the next start comes back held.
        #expect(AddonHoldStore(url: h.runtime.paths.holdState).read() != .absent)
        #expect(await h.loop.handleAddonIPC(.hold(addon: "io.example.second", vmBytes: 0, leaseSeconds: 60),
            peer: AddonPeer(identifier: "io.example.second")) == .failure(.unavailable))
        // Releasing during the stop never reopens admission.
        #expect(await h.loop.handleAddonIPC(.release(holdID: id), peer: Self.peer) == .released)
        #expect(await h.loop.state.refusingNewWork)
    }

    @Test func anExpiredLeaseReleasesOnlyWhenTheMachineLockIsFree() async throws {
        let h = try await harness()
        defer { h.remove() }
        let id = try Self.holdID(await h.hold(lease: 30))
        try await h.awaitState(id, .held)
        let lock = try h.runtime.holdMachineLock()
        h.clock.advance(seconds: 31)
        #expect(await h.loop.enforceAddonHoldLeases())
        #expect(await h.status(id) == .status(state: .held, sinceMs: h.clock.now - 31_000,
                                              leaseExpiresAtMs: h.clock.now - 1_000))
        #expect(await h.loop.state.refusingNewWork)
        // A renewal while kept restarts the lease from now.
        #expect(await h.loop.handleAddonIPC(.renew(holdID: id, leaseSeconds: 30), peer: Self.peer)
            == .renewed(state: .held, leaseExpiresAtMs: h.clock.now + 30_000))
        h.clock.advance(seconds: 31)
        #expect(await h.loop.enforceAddonHoldLeases())
        flock(lock, LOCK_UN)
        close(lock)
        #expect(await !h.loop.enforceAddonHoldLeases())
        #expect(await h.status(id) == .status(state: .expired, sinceMs: h.clock.now - 62_000,
                                              leaseExpiresAtMs: h.clock.now - 1_000))
        #expect(await !h.loop.state.refusingNewWork)
        #expect(AddonHoldStore(url: h.runtime.paths.holdState).read() == .absent)
    }

    @Test func aRestartComesBackHeldWhileTheLeaseIsValidOrTheLockIsHeld() async throws {
        let h = try await harness()
        defer { h.remove() }
        let id = try Self.holdID(await h.hold(lease: 60))
        try await h.awaitState(id, .held)
        // The old process exits; its lease monitor must not outlive it here.
        await h.loop.stopAddonHoldServiceForTesting()

        // A replacement process reads the same runtime directory.
        let restarted = try await ModelLoadingFixtures.makeLoop(sandbox: h.sandbox)
        await restarted.useAddonHoldForTesting(paths: h.runtime.paths, clock: h.clock)
        await restarted.restartAddonHoldServiceForTesting()
        #expect(await restarted.addonHoldDrainOwner() == .addonHold)
        #expect(await restarted.state.refusingNewWork)
        #expect(await restarted.state.busy?.addon == Self.addon)
        #expect(await restarted.addonHoldsForTesting().map(\.holdID) == [id])
        #expect(await restarted.runStartupPreloadGateForTesting() == .cancelled)
        await restarted.stopAddonHoldServiceForTesting()

        // Expired but the lock is held (VMs still running): restored.
        let lock = try h.runtime.holdMachineLock()
        h.clock.advance(seconds: 61)
        let expired = try await ModelLoadingFixtures.makeLoop(sandbox: h.sandbox)
        await expired.useAddonHoldForTesting(paths: h.runtime.paths, clock: h.clock)
        await expired.restartAddonHoldServiceForTesting()
        #expect(await expired.addonHoldDrainOwner() == .addonHold)
        await expired.stopAddonHoldServiceForTesting()
        flock(lock, LOCK_UN)
        close(lock)
        // Expired with no lock: not restored, and the record is cleared.
        let free = try await ModelLoadingFixtures.makeLoop(sandbox: h.sandbox)
        await free.useAddonHoldForTesting(paths: h.runtime.paths, clock: h.clock)
        await free.restartAddonHoldServiceForTesting()
        await free.stopAddonHoldServiceForTesting()
        #expect(await free.addonHoldDrainOwner() == nil)
        #expect(await !free.state.refusingNewWork)
        #expect(AddonHoldStore(url: h.runtime.paths.holdState).read() == .absent)
    }

    @Test func operatorControlHoldsAndRefusesAnUnforcedReleaseWhileTheLockIsHeld() async throws {
        let h = try await harness()
        defer { h.remove() }
        let identity = try #require(ProcessIdentity.current())
        let held = await h.loop.handleAddonControl(.init(target: identity, action: .hold, leaseSeconds: 45))
        #expect(held.failure == nil && held.holds.map(\.addon) == [AddonHoldControlRequest.operatorAddon])
        #expect(await h.loop.state.busy?.addon == AddonHoldControlRequest.operatorAddon)
        let lock = try h.runtime.holdMachineLock()
        let refused = await h.loop.handleAddonControl(.init(target: identity, action: .release))
        #expect(refused.failure == .machineLockHeld && refused.machineLockHeld && refused.holds.count == 1)
        let forced = await h.loop.handleAddonControl(.init(target: identity, action: .release, force: true))
        #expect(forced.failure == nil && forced.holds.isEmpty)
        flock(lock, LOCK_UN)
        close(lock)
        #expect(await !h.loop.state.refusingNewWork)

        // The mailbox round trip a `darkbloom addon status` performs.
        let mailbox = LifecycleMailbox(identity: identity, directory: h.sandbox.root.appendingPathComponent("lifecycle"))
        let request = AddonHoldControlRequest(target: identity, action: .status)
        try mailbox.writeAddonRequest(request)
        let answered = try #require(await h.loop.acceptPendingAddonControl(from: mailbox))
        #expect(answered.requestID == request.id && mailbox.readAddonStatus() == answered)
        #expect(await h.loop.acceptPendingAddonControl(from: mailbox) == nil)
        #expect(!AddonHoldControlRequest(target: identity, action: .hold, leaseSeconds: 10).isValid(for: identity))
        #expect(!AddonHoldControlRequest(target: identity, action: .status, leaseSeconds: 30).isValid(for: identity))
    }
}

extension ProviderLoop {
    func stopAddonHoldServiceForTesting() { stopAddonHoldService() }
}

func addonEventually(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
