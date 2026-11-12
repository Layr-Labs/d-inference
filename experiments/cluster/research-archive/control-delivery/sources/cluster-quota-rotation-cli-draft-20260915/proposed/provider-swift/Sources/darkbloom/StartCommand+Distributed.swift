import Foundation
import ArgumentParser
import ProviderCore

extension Start {
    /// A distributed leader loads only verified tokenizer metadata here. Its
    /// local native owner child acquires the shared device exclusion.
    func runLocalDistributed() async throws {
        let configPath = try configOptions.config.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        } ?? ConfigManager.defaultConfigPath()
        let factory = try DistributedStartSessionFactory(providerConfiguration: configPath)
        let session = try await factory.prepare()
        let token = try noAuth ? nil : LocalEndpoint.loadOrCreateToken()
        let budget = try DistributedFirstTokenBudgetPolicy(
            baseMilliseconds: 10_000, millisecondsPerInputToken: 1)
        let server = DistributedLocalServer(
            session: session, config: .init(host: bind, port: port, authToken: token),
            firstTokenBudgetPolicy: budget,
            replacementSessionFactory: { try await factory.prepare() })

        // Keep the existing endpoint/PID and sleep-prevention ownership. The
        // cluster leader never takes the native device gate from its own child.
        try ProcessLifecycle.acquireMediaServingLock()
        ProcessLifecycle.preventSystemSleep()
        defer { ProcessLifecycle.releaseSingleInstanceLock() }
        let signals = try DistributedStartSignals()
        defer { signals.close() }

        let task = Task {
            try await server.start()
            guard let boundPort = await server.status.boundPort else {
                throw DistributedStartRuntimeError.listenerStopped
            }
            print("darkbloom \(ProviderCore.version) (local / distributed)")
            print("Model: \(session.model.publicModelID)")
            print("Listening on \(bind):\(boundPort); connection details: darkbloom local")
            return await withFanActivityLease(providerVersion: ProviderCore.version) {
                await server.waitUntilStopped()
            }
        }
        let stop: @Sendable () -> Void = {
            task.cancel()
            Task { _ = await server.stop(until: DispatchTime.now().uptimeNanoseconds + 15_000_000_000) }
        }
        signals.attach(stop)
        let status: DistributedLocalServerStatus
        do {
            status = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { stop() }
        } catch {
            // A separate task keeps cancellation of the command from reducing
            // the bounded cleanup wait to an immediate cancelled sleep.
            let cleanup = Task {
                await server.stop(until: DispatchTime.now().uptimeNanoseconds + 15_000_000_000)
            }
            let status = await cleanup.value
            if !status.cleanupComplete {
                printError("Distributed cleanup is unresolved; owner journals continue to block another session.")
            }
            throw error
        }
        guard status.cleanupComplete else {
            throw DistributedStartRuntimeError.cleanupUnresolved
        }
        if status.failed { throw DistributedStartRuntimeError.sessionFailed }
    }
}
