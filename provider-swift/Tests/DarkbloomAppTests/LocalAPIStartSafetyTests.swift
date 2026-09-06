import Foundation
import Testing
@testable import DarkbloomApp

@Suite("Local start conflicts and cancellation", .timeLimit(.minutes(1)))
@MainActor
struct LocalAPIStartSafetyTests {
    @Test("Explicit rollout opt-out disables native launch without entering the runner")
    func disabledLaunchCannotRun() async {
        let cli = LocalAPIRecordingCLI()
        let store = LocalAPIStore.live(
            discoveryReader: { nil }, processIdentityReader: { _ in nil }, cli: cli,
            startConfiguration: .init(nonReplacingLaunchVerified: false),
            providerConflictReader: { nil }
        )
        requestLocalAPIStart(store)
        #expect(store.localStart.state == .failed(.nonReplacingLaunchUnavailable))
        #expect(!store.localStart.isLaunchSupported)
        #expect(await cli.invocations.isEmpty)
    }

    @Test("Existing network, transitioning, and scheduled providers are never stopped or replaced")
    func providerConflicts() async {
        let cli = LocalAPIRecordingCLI()
        let store = localAPIStartStore(cli: cli, world: LocalAPIStartWorld())
        let model = localAPIInstalledModel()
        let states: [ProviderRunState] = [.online, .serving, .starting, .stopping, .restarting, .scheduledOff]
        for state in states {
            var provider = ProviderPreviewScenario.paused.snapshot
            provider.runState = state
            store.startLocalOnly(modelID: model.id, models: [model], modelsAreLive: true, providerSnapshot: provider)
            #expect(store.localStart.state == .failed(.conflict(state.isTransitioning ? .providerTransitioning : .providerRunning)))
        }
        #expect(await cli.invocations.isEmpty)
    }

    @Test("An existing endpoint blocks another local start even before its health probe")
    func existingLocalEndpoint() async {
        let cli = LocalAPIRecordingCLI()
        let world = LocalAPIStartWorld()
        world.publish(localAPIStartInfo(), models: [localAPIInstalledModel().id])
        let store = localAPIStartStore(cli: cli, world: world)
        #expect(store.endpoint?.health == .checking)
        requestLocalAPIStart(store)
        #expect(store.localStart.state == .failed(.conflict(.localEndpoint)))
        #expect(await cli.invocations.isEmpty)
        #expect(world.probeCount == 0)
    }

    @Test("Stale heartbeat with a live PID and missing parent state fail closed")
    func unknownProviderState() async {
        let cli = LocalAPIRecordingCLI()
        let world = LocalAPIStartWorld()
        let store = localAPIStartStore(cli: cli, world: world)
        let model = localAPIInstalledModel()
        let info = localAPIStartInfo()
        world.setIdentity(info.processIdentity)
        var provider = ProviderPreviewScenario.stale.snapshot
        provider.pid = info.pid
        store.startLocalOnly(modelID: model.id, models: [model], modelsAreLive: true, providerSnapshot: provider)
        #expect(store.localStart.state == .failed(.conflict(.providerStateUncertain)))
        store.startLocalOnly(modelID: model.id, models: [model], modelsAreLive: true, providerSnapshot: nil)
        #expect(store.localStart.state == .failed(.conflict(.providerStateUncertain)))
        #expect(await cli.invocations.isEmpty)
    }

    @Test("Read-only daemon conflict is honored even when the parent snapshot says paused")
    func freshConflictReader() async {
        let cli = LocalAPIRecordingCLI()
        let store = localAPIStartStore(cli: cli, world: LocalAPIStartWorld(), providerConflictReader: { .providerRunning })
        requestLocalAPIStart(store)
        #expect(store.localStart.state == .failed(.conflict(.providerRunning)))
        #expect(await cli.invocations.isEmpty)
    }

    @Test("Queued starts recheck newly appeared endpoint evidence before entering the runner")
    func conflictBetweenTapAndLaunch() async {
        let cli = LocalAPIRecordingCLI()
        let world = LocalAPIStartWorld()
        let store = localAPIStartStore(cli: cli, world: world)
        requestLocalAPIStart(store)
        world.publish(localAPIStartInfo(), models: [localAPIInstalledModel().id])
        #expect(await localAPIEventually { store.localStart.state == .failed(.conflict(.localEndpoint)) })
        #expect(await cli.invocations.isEmpty)
    }

    @Test("Cancellation before runner entry never launches; repeated taps do not duplicate the command")
    func cancelBeforeLaunch() async {
        let cli = LocalAPIRecordingCLI()
        let store = localAPIStartStore(cli: cli, world: LocalAPIStartWorld())
        requestLocalAPIStart(store)
        requestLocalAPIStart(store)
        store.localStart.cancel()
        #expect(await localAPIEventually { store.localStart.state == .cancelled })
        #expect(await cli.invocations.isEmpty)
    }

    @Test("An already cancelled caller cannot schedule a local start")
    func alreadyCancelledCaller() async {
        let cli = LocalAPIRecordingCLI()
        let store = localAPIStartStore(cli: cli, world: LocalAPIStartWorld())
        let gate = LocalAPIProbeGate()
        let request = Task { @MainActor in
            await gate.wait()
            requestLocalAPIStart(store)
        }
        request.cancel()
        await gate.open()
        await request.value
        #expect(store.localStart.state == .cancelled)
        #expect(await cli.invocations.isEmpty)
    }

    @Test("Cancellation ignores late command success and blocks retries until the old task returns")
    func lateCommandAfterCancel() async {
        let cli = LocalAPIRecordingCLI()
        let store = localAPIStartStore(cli: cli, world: LocalAPIStartWorld())
        requestLocalAPIStart(store)
        #expect(await localAPIEventually { await cli.invocations.count == 1 })
        store.localStart.cancel()
        requestLocalAPIStart(store)
        #expect(store.localStart.state == .cancelling)
        #expect(await cli.invocations.count == 1)
        await cli.resolve()
        #expect(await localAPIEventually { store.localStart.state == .cancelled })
        #expect(!store.localStart.hasActiveSession)
        requestLocalAPIStart(store)
        #expect(await localAPIEventually { await cli.invocations.count == 2 })
        #expect(store.localStart.state.isWaiting)
        store.localStart.cancel()
        await cli.resolve()
    }

    @Test("Cancelled late probes cannot publish ready or replace a later command error")
    func lateProbeAfterCancel() async {
        let cli = LocalAPIRecordingCLI()
        let gate = LocalAPIProbeGate()
        let world = LocalAPIStartWorld(probeGate: gate)
        let store = localAPIStartStore(cli: cli, world: world)
        requestLocalAPIStart(store)
        #expect(await localAPIEventually { await cli.invocations.count == 1 })
        world.publish(localAPIStartInfo(), models: [localAPIInstalledModel().id])
        #expect(await localAPIEventually { world.probeCount > 0 })
        store.localStart.cancel()
        world.publish(nil, models: [])
        await cli.resolve()
        #expect(await localAPIEventually { store.localStart.state == .cancelled })
        requestLocalAPIStart(store)
        #expect(await localAPIEventually { await cli.invocations.count == 2 })
        await cli.resolve(.failure(ProviderCLIError.exited(3, message: "rejected")))
        #expect(await localAPIEventually { store.localStart.state == .failed(.cli(.exited(3, message: "rejected"))) })
        await gate.open()
        await store.refreshNow()
        #expect(store.localStart.state == .failed(.cli(.exited(3, message: "rejected"))))
        #expect(store.endpoint == nil)
    }

    @Test("PID reuse during a suspended probe is rejected without waiting for another refresh tick")
    func pidReuseDuringProbe() async {
        let cli = LocalAPIRecordingCLI()
        let gate = LocalAPIProbeGate()
        let world = LocalAPIStartWorld(probeGate: gate)
        world.publish(localAPIStartInfo(), models: [localAPIInstalledModel().id])
        let store = localAPIStartStore(cli: cli, world: world)
        let probe = Task { await store.refreshNow(forceProbe: true) }
        #expect(await localAPIEventually { world.probeCount > 0 })
        world.reusePID()
        await gate.open()
        await probe.value
        #expect(store.endpoint == nil)
        #expect(await cli.invocations.isEmpty)
    }
}
