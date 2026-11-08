// Only me's own server, from its construction until it listens (`--local --here`, and launchd's child of Only me's
// background service): the steps `runLocalStandalone` takes, in order, over `OnlyMeServer`.
import ArgumentParser
import Foundation
import ProviderCore

/// Only me's own server as `Start.startOnlyMeServer` drives it: `StandaloneServer`, or a test's stand-in (building a
/// `StandaloneServer` needs Metal).
protocol OnlyMeServer: Actor {
    func startLifecycleControl(stateFile: URL)
    func preloadSelectedModels(configuredModelIDs: [String]) async -> StartupPreloader.Summary
    func start() throws
    func waitUntilBound(timeoutSeconds: Double) async -> Bool
    func stop() async
    func drainAndStop(timeoutSeconds: Int) async -> Bool
    func startIdleUnload(minutes: UInt64, every interval: Duration)
    func startAutoUpdateMonitor(coordinatorURL: String, enabled: Bool, environment: [String: String])
}

extension StandaloneServer: OnlyMeServer {}

extension Start {
    /// Only me's own server from its construction until it listens. First, as the network provider does
    /// (`runForeground`, `ProviderLoop.run`): for launchd's job alone (`launchdJob`; never `--here` or a cluster's solo
    /// part) the release confirmation (`confirmRelease`), then the heartbeat (the daemon state, kept fresh, and the
    /// lifecycle mailbox). So the preload, which waits for every model with no time limit, never reads as a hung start
    /// to the watchdog, and `stop` or `restart` can drain it. Then the preload, the listener, the idle unload and, for
    /// launchd's job, the update loop. False when a stop came first.
    func startOnlyMeServer<Server: OnlyMeServer>(
        _ server: Server, config: ProviderConfig, serving: StartServing,
        termination: ProviderTermination = .shared, stateFile: URL = DaemonStateFile.path(),
        launchdJob: Bool = LaunchAgent.isCurrentProcessJob(),
        confirmRelease: (_ coordinatorURL: String) -> Void = Start.confirmRunningRelease(coordinatorURL:)
    ) async throws -> Bool {
        let coordinator = coordinatorURL ?? config.coordinator.url
        let updatesItself = foreground && launchdJob
        if updatesItself { confirmRelease(coordinator) }
        await server.startLifecycleControl(stateFile: stateFile)
        guard await runLocalStartupPreload(server: server, config: config, termination: termination) else { return false }
        try await server.start()
        await termination.install {
            await server.drainAndStop(timeoutSeconds: ProviderTermination.timeoutSeconds)
        }
        if await termination.terminationRequested {
            await server.stop()
            return false
        }

        // Wait until the server CONFIRMS it bound the port before advertising it.
        // start() launches Hummingbird in a child task and returns before the
        // bind completes; we must not write a discovery record pointing at a dead
        // (or, worse, a foreign) endpoint that `darkbloom local` / local-first
        // clients would then trust. waitUntilBound reads the actor's own bind
        // signal (Hummingbird onServerRunning), not an HTTP probe a process
        // already holding the port could answer.
        guard await server.waitUntilBound(timeoutSeconds: 5.0) else {
            await server.stop()
            printError(Self.localServerBindFailure(bind: serving.bind, port: serving.port,
                                                   nextFree: LocalAPIPort.nextFree(besides: serving.port),
                                                   paired: ClusterPairSummary.local().paired))
            throw ExitCode.failure
        }
        print("Listening on \(serving.bind):\(serving.port)")
        // Only now that the start went ahead is a new port (or a settings flag) saved: a start refused above (no model
        // it can serve, the running provider's drain, a port another program holds) saves nothing. This server runs
        // for `--here`, which saves no mode, and for a service's child, which saves nothing.
        try saveServingChoice(serving)

        // Models idle past the saved memory setting are unloaded, as the other two choices do.
        await server.startIdleUnload(minutes: config.backend.idleTimeoutMins,
                                     every: StandaloneServer.idleUnloadCheckInterval)
        // Only me's background service updates itself as the network provider does; `--here` and a cluster's solo part
        // don't.
        if updatesItself {
            await server.startAutoUpdateMonitor(coordinatorURL: coordinator, enabled: config.provider.autoUpdate,
                                                environment: ProcessInfo.processInfo.environment)
        }
        return true
    }

    /// Tells the watchdog's update recovery that the release this process runs has started
    /// (`SelfUpdater.confirmRunningCandidateLaunch`).
    static func confirmRunningRelease(coordinatorURL: String) {
        guard let identity = ProcessIdentity.current() else { return }
        try? SelfUpdater(coordinatorBaseURL: coordinatorURL).confirmRunningCandidateLaunch(
            processStartedAt: Double(identity.startTimeMicros) / 1_000_000)
    }
}
