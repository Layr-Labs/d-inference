import Foundation
import Testing
@testable import DarkbloomApp

@Suite("Owned foreground local session lifetime", .timeLimit(.minutes(1)))
@MainActor
struct LocalAPIProcessLifetimeTests {
    @Test("A different trusted local process cannot satisfy readiness for this app's child")
    func readinessIsBoundToOwnedChild() async {
        let cli = LocalAPIRecordingCLI()
        let world = LocalAPIStartWorld()
        let store = localAPIStartStore(cli: cli, world: world)
        let model = localAPIInstalledModel()
        requestLocalAPIStart(store)
        #expect(await localAPIEventually { await cli.invocations.count == 1 })
        world.publish(localAPIStartInfo(pid: 9943), models: [model.id])
        #expect(await localAPIEventually { store.endpoint?.health == .reachable })
        #expect(store.localStart.state.isWaiting)
        #expect(store.localStart.ownedProcessIdentity?.pid == 9942)
        world.publish(localAPIStartInfo(), models: [model.id])
        #expect(await localAPIEventually { store.localStart.state == .ready(modelID: model.id) })
        store.localStart.cancel()
        await cli.resolve()
    }

    @Test("Quit waits for the owned child to complete cancellation")
    func quitAwaitsChild() async {
        let cli = LocalAPIRecordingCLI()
        let store = localAPIStartStore(cli: cli, world: LocalAPIStartWorld())
        requestLocalAPIStart(store)
        #expect(await localAPIEventually { await cli.invocations.count == 1 })
        let quit = Task { await store.prepareForApplicationTermination() }
        #expect(await localAPIEventually { store.localStart.state == .cancelling })
        #expect(store.localStart.hasActiveSession)
        await cli.resolve()
        #expect(await quit.value)
        #expect(!store.localStart.hasActiveSession)
        #expect(store.localStart.ownedProcessIdentity == nil)
    }

    @Test("Quit is refused within a bound if the owned child has not stopped")
    func quitDoesNotOrphanUnconfirmedChild() async {
        let cli = LocalAPIRecordingCLI()
        let store = localAPIStartStore(cli: cli, world: LocalAPIStartWorld(), shutdownTimeout: .milliseconds(30))
        requestLocalAPIStart(store)
        #expect(await localAPIEventually { await cli.invocations.count == 1 })
        #expect(await store.prepareForApplicationTermination() == false)
        #expect(store.localStart.hasActiveSession)
        #expect(store.localStart.state == .failed(.shutdownTimedOut))
        requestLocalAPIStart(store)
        #expect(await cli.invocations.count == 1)
        await cli.resolve()
        #expect(await localAPIEventually { !store.localStart.hasActiveSession })
    }

    @Test("Quit with only an externally discovered endpoint invokes no process command")
    func quitLeavesExternalEndpointAlone() async {
        let cli = LocalAPIRecordingCLI()
        let world = LocalAPIStartWorld()
        world.publish(localAPIStartInfo(), models: [localAPIInstalledModel().id])
        let store = localAPIStartStore(cli: cli, world: world)
        #expect(await store.prepareForApplicationTermination())
        #expect(world.info != nil)
        #expect(await cli.invocations.isEmpty)
    }

    @Test("Dedicated foreground runner rejects pre-cancelled calls before locating an executable")
    func preCancelledForegroundLaunch() async {
        let locator = LocalAPINilLocator()
        let runner = ProcessLocalAPIProviderRunner(locator: locator)
        let gate = LocalAPIProbeGate()
        let launch = Task {
            await gate.wait()
            return try await runner.run(arguments: ["start", "--local", "--model", "local/test"], onLaunch: { _ in })
        }
        launch.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await launch.value }
        #expect(locator.calls == 0)
    }
}

private final class LocalAPINilLocator: DarkbloomCLILocating, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func locate() -> URL? {
        lock.withLock { count += 1 }
        return nil
    }
}
