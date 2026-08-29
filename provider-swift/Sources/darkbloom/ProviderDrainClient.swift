import Foundation
import ProviderCore

struct ProviderDrainClient: Sendable {
    enum Outcome: Sendable, Equatable {
        case notRunning
        case drained
        case timedOut([ProcessIdentity])
    }

    struct Dependencies: Sendable {
        var snapshots: @Sendable () -> [ProviderLaunchSnapshot]
        var signal: @Sendable (String) throws -> Void
        var waitForExit: @Sendable (ProcessIdentity, Duration) async -> Bool

        static let live = Dependencies(
            snapshots: { LaunchAgent.launchSnapshots() },
            signal: { try LaunchAgent.requestGracefulExit(label: $0) },
            waitForExit: { identity, timeout in
                await ProcessLifecycle.waitForExit(identity, timeout: timeout)
            }
        )
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    /// Ask every loaded provider job to drain, then wait for the exact captured
    /// process identities to exit. No timeout path sends SIGKILL.
    func drain(
        timeout: Duration = ProviderLoop.operatorDrainTimeout + .seconds(2)
    ) async throws -> Outcome {
        let running = dependencies.snapshots().compactMap { snapshot -> (String, ProcessIdentity)? in
            guard let process = snapshot.process else { return nil }
            return (snapshot.label, process)
        }
        guard !running.isEmpty else { return .notRunning }

        for (label, _) in running {
            try dependencies.signal(label)
        }

        let timedOut = await withTaskGroup(of: ProcessIdentity?.self) { group in
            for (_, identity) in running {
                group.addTask {
                    await dependencies.waitForExit(identity, timeout) ? nil : identity
                }
            }
            var identities: [ProcessIdentity] = []
            for await identity in group {
                if let identity { identities.append(identity) }
            }
            return identities.sorted { $0.pid < $1.pid }
        }

        return timedOut.isEmpty ? .drained : .timedOut(timedOut)
    }
}

enum ProviderDrainCommandError: Error, CustomStringConvertible {
    case timedOut([ProcessIdentity])

    var description: String {
        switch self {
        case .timedOut(let identities):
            let pids = identities.map { String($0.pid) }.joined(separator: ", ")
            return "active requests did not finish within 600 seconds (provider PID \(pids)); action cancelled and serving resumed"
        }
    }
}

@discardableResult
func drainProviderBeforeLifecycleAction(
    _ action: String,
    client: ProviderDrainClient = ProviderDrainClient()
) async throws -> ProviderDrainClient.Outcome {
    print("Draining active requests before \(action)...")
    let outcome = try await client.drain()
    if case .timedOut(let identities) = outcome {
        throw ProviderDrainCommandError.timedOut(identities)
    }
    return outcome
}
