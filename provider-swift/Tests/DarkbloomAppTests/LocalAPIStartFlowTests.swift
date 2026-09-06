import Foundation
import Testing
@testable import DarkbloomApp

@Suite("Native local-only start", .timeLimit(.minutes(1)))
@MainActor
struct LocalAPIStartFlowTests {
    @Test("Exact argv retains the installed model as one argument and CLI text quotes it")
    func exactArguments() async throws {
        let model = localAPIInstalledModel(id: "local/a b'$(touch nope)")
        let cli = LocalAPIRecordingCLI()
        let world = LocalAPIStartWorld()
        let store = localAPIStartStore(cli: cli, world: world)
        requestLocalAPIStart(store, model: model)
        #expect(await localAPIEventually { await cli.invocations.count == 1 })
        let calls = await cli.invocations
        #expect(calls.first?.arguments == ["start", "--local", "--model", model.id, "--no-replace"])
        #expect(store.text(for: .command(.directOnly)) == "darkbloom start --local --model 'local/a b'\"'\"'$(touch nope)' --no-replace")
        #expect(store.localStart.state == .waitingForEndpoint(modelID: model.id))
        store.localStart.cancel()
        await cli.resolve()
        #expect(await localAPIEventually { store.localStart.state == .cancelled })
    }

    @Test("Readiness requires a new authenticated loopback probe advertising the requested model")
    func trustedReadiness() async {
        let cli = LocalAPIRecordingCLI()
        let world = LocalAPIStartWorld()
        let store = localAPIStartStore(cli: cli, world: world)
        let model = localAPIInstalledModel()
        requestLocalAPIStart(store)
        #expect(await localAPIEventually { await cli.invocations.count == 1 })
        #expect(store.endpoint == nil)
        world.publish(localAPIStartInfo(), models: ["some-other-model"])
        #expect(await localAPIEventually { world.probeCount > 0 })
        #expect(store.localStart.state.isWaiting)
        world.publish(localAPIStartInfo(), models: [model.id])
        #expect(await localAPIEventually { store.localStart.state == .ready(modelID: model.id) })
        #expect(store.endpoint?.health == .reachable)
        #expect(store.endpoint?.mode == nil) // discovery does not report mode
        #expect(store.localStart.hasActiveSession)
        store.stopMonitoring() // navigation to Chat does not kill the session
        #expect(store.localStart.hasActiveSession)
        await cli.resolve()
        #expect(await localAPIEventually { store.localStart.state == .failed(.processExited) })
    }

    @Test("A zero exit without endpoint appearance is a failure")
    func exitIsNotReady() async {
        let cli = LocalAPIRecordingCLI()
        let store = localAPIStartStore(cli: cli, world: LocalAPIStartWorld())
        requestLocalAPIStart(store)
        #expect(await localAPIEventually { await cli.invocations.count == 1 })
        await cli.resolve()
        #expect(await localAPIEventually { store.localStart.state == .failed(.processExited) })
        #expect(store.endpoint == nil)
    }

    @Test("CLI rejection remains typed; a nonthrowing nonzero result is rejected too")
    func typedRejection() async {
        let cli = LocalAPIRecordingCLI()
        let store = localAPIStartStore(cli: cli, world: LocalAPIStartWorld())
        requestLocalAPIStart(store)
        #expect(await localAPIEventually { await cli.invocations.count == 1 })
        await cli.resolve(.failure(ProviderCLIError.cliNotFound))
        #expect(await localAPIEventually { store.localStart.state == .failed(.cli(.cliNotFound)) })
        requestLocalAPIStart(store)
        #expect(await localAPIEventually { await cli.invocations.count == 2 })
        await cli.resolve(.success(.init(exitStatus: 7, stderrTail: "port is occupied")))
        #expect(await localAPIEventually {
            store.localStart.state == .failed(.cli(.exited(7, message: "port is occupied")))
        })
    }

    @Test("A readiness deadline does not wait for an uncooperative probe or stop the running session")
    func boundedReadiness() async {
        let cli = LocalAPIRecordingCLI()
        let gate = LocalAPIProbeGate()
        let deadline = LocalAPIManualDeadline()
        let world = LocalAPIStartWorld(probeGate: gate)
        let store = localAPIStartStore(cli: cli, world: world, waitForReadinessTimeout: { _ in
            await deadline.wait()
        })
        let model = localAPIInstalledModel()
        requestLocalAPIStart(store)
        #expect(await localAPIEventually { await cli.invocations.count == 1 })
        world.publish(localAPIStartInfo(), models: [model.id])
        #expect(await localAPIEventually { world.probeCount > 0 })
        #expect(await localAPIEventually { await deadline.isWaiting })
        await deadline.fire()
        #expect(await localAPIEventually {
            store.localStart.state == .failed(.readinessTimedOut(modelID: model.id))
        })
        #expect(store.localStart.hasActiveSession)
        await gate.open()
        #expect(store.localStart.state == .failed(.readinessTimedOut(modelID: model.id)))
        store.localStart.checkAgain()
        #expect(await localAPIEventually { store.localStart.state == .ready(modelID: model.id) })
        #expect(await cli.invocations.count == 1) // retry observes; never relaunches
        store.localStart.cancel()
        await cli.resolve()
        await deadline.fire()
    }

    @Test("Fixture data, uninstalled rows, and runtime-ineligible rows cannot launch")
    func validatesInput() async {
        let cli = LocalAPIRecordingCLI()
        let store = localAPIStartStore(cli: cli, world: LocalAPIStartWorld())
        var model = localAPIInstalledModel()
        store.startLocalOnly(modelID: model.id, models: [model], modelsAreLive: false,
                             providerSnapshot: ProviderPreviewScenario.paused.snapshot)
        #expect(store.localStart.state == .failed(.fixtureMode))
        model.installation = .notInstalled
        requestLocalAPIStart(store, model: model)
        #expect(store.localStart.state == .failed(.modelNotInstalled))
        model.installation = .installed
        model.fit = .runtimeIneligible(reason: "Adapter unavailable")
        requestLocalAPIStart(store, model: model)
        #expect(store.localStart.state == .failed(.modelUnavailable("Adapter unavailable")))
        let fixture = LocalAPIStore(fixture: .stopped)
        requestLocalAPIStart(fixture)
        #expect(fixture.localStart.state == .failed(.fixtureMode))
        #expect(await cli.invocations.isEmpty)
    }
}

private actor LocalAPIManualDeadline {
    private var pending: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { pending != nil }
    func wait() async { await withCheckedContinuation { pending = $0 } }
    func fire() {
        pending?.resume()
        pending = nil
    }
}
