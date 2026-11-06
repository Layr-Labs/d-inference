import Foundation
import ProviderCore

extension Start {
    func runLocalProtectedDistributed(factory: DistributedStartSessionFactory) async throws {
        try ProcessLifecycle.acquireMediaServingLock()
        ProcessLifecycle.preventSystemSleep()
        defer { ProcessLifecycle.releaseSingleInstanceLock() }
        let signals = try DistributedStartSignals()
        defer { signals.close() }
        let member = try await makeClusterMemberLoop(reference: factory.reference, stopOnDisconnect: true)
        let token = try noAuth ? nil : LocalEndpoint.loadOrCreateToken()
        let address = bind, selectedPort = port
        let task = Task {
            try await member.runProtectedLocalServer(reference: factory.reference,
                providerConfiguration: factory.providerConfiguration,
                config: .init(host: address, port: selectedPort, authToken: token)) { model, port in
                    print("darkbloom \(ProviderCore.version) (local / protected distributed)")
                    print("Model: \(model)")
                    print("Listening on \(address):\(port); connection details: darkbloom local")
                    print("Supported request shape: exactly 32 input tokens, 2 output tokens, greedy sampling, no stop sequences.")
                }
        }
        signals.attach { task.cancel() }
        let status = try await withTaskCancellationHandler {
            try await withFanActivityLease(providerVersion: ProviderCore.version) { try await task.value }
        } onCancel: { task.cancel() }
        guard status.cleanupComplete else { throw DistributedStartRuntimeError.cleanupUnresolved }
        if status.failed { throw DistributedStartRuntimeError.sessionFailed }
    }
}
