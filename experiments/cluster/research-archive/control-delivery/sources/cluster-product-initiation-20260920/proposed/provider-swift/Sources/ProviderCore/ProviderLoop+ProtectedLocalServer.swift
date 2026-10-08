import Foundation
import MLXLMCommon

extension ProviderLoop {
    /// One explicitly selected local protected cohort. Authorization comes only
    /// from the current real coordinator connection; metadata is not a grant.
    public func runProtectedLocalServer(reference: ClusterConfigurationReference,
                                        providerConfiguration: URL, config: LocalInferenceHTTPConfig,
                                        onReady: @escaping @Sendable (String, UInt16) -> Void) async throws -> DistributedLocalServerStatus {
        guard isClusterMember, loopConfig.clusterMemberStopsOnDisconnect, !nativePairConfigurationClosed,
              coordinatorClient == nil, let control = nativePairMemberControl else { throw NativePairMemberError.unconfigured }
        guard control.installation.protectedRuntime?.configurationIntent?.rank == 0 else {
            throw ClusterConfigurationError.invalid("Protected local start requires matching coordinator membership saved on both Macs")
        }
        // Claim the already installed configuration before creating any task.
        nativePairConfigurationClosed = true
        let lifecycle = ProtectedLocalStartLifecycle(closeControl: { control.closeLocalServing() })
        let memberTask = Task { try await self.run() }
        let memberExit = Task {
            let result = await memberTask.result
            await lifecycle.stop()
            return result
        }
        do {
            try await withTaskCancellationHandler {
                try await waitForClusterMemberRegistration(until: .now.advanced(by: .seconds(30)))
                // Capture the current connection before another suspension. The
                // stop lifecycle also fences a cancellation before this point.
                let scope = try control.localStart()
                try await lifecycle.install(scope)
                let session = try await protectedMemberSession(reference: reference,
                    providerConfiguration: providerConfiguration,
                    deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 90_000_000_000,
                    localStart: scope)
                let server = DistributedLocalServer(session: session, config: config,
                    firstTokenBudgetPolicy: nil,
                    tokenizerLoader: { TokenizerHandle(try await LocalTokenizerLoader().load(from: $0)) },
                    discovery: .local)
                try await lifecycle.install(server)
                try Task.checkCancellation()
                try await server.start()
                guard let port = await server.status.boundPort else { throw DistributedLocalServerError.bindFailed }
                onReady(session.model.publicModelID, port)
                _ = await server.waitUntilStopped()
            } onCancel: { Task { await lifecycle.stop() } }
            let status = await Task { await lifecycle.finish() }.value
            // Release messages and signer/transport joins have had their real
            // connection. Only now end the member loop and join its watcher.
            memberTask.cancel()
            let memberResult = await memberExit.value
            guard let status else { throw DistributedLocalServerError.startupInterrupted }
            if case .failure(let error) = memberResult, !(error is CancellationError) { throw error }
            return status
        } catch {
            _ = await Task { await lifecycle.finish() }.value
            memberTask.cancel(); _ = await memberExit.value
            throw error
        }
    }
}
