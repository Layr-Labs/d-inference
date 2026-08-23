import Foundation
import ProviderCore

/// Prevents the crash watchdog from relaunching a provider that intentionally
/// exits after a successful operator drain. A failed drain restores the prior
/// watchdog job before the stop command returns an error.
struct WatchdogDrainTransaction: Sendable {
    struct Snapshot: Sendable, Equatable {
        let wasLoaded: Bool
        let configPath: URL?
    }

    struct Dependencies: Sendable {
        var snapshot: @Sendable () -> Snapshot
        var disarm: @Sendable () throws -> Void
        var rearm: @Sendable (URL?) throws -> Void

        static let live = Dependencies(
            snapshot: {
                Snapshot(
                    wasLoaded: WatchdogAgent.isLoaded(),
                    configPath: WatchdogAgent.installedConfigPath()
                )
            },
            disarm: { try WatchdogAgent.stop() },
            rearm: { try WatchdogAgent.installAndStart(configPath: $0) }
        )
    }

    enum TransactionError: Error, CustomStringConvertible {
        case restoreFailed(drain: String, restore: String)

        var description: String {
            switch self {
            case .restoreFailed(let drain, let restore):
                return "\(drain); crash recovery could not be restored: \(restore)"
            }
        }
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    func run(
        drain: @escaping @Sendable () async throws -> Void
    ) async throws {
        let snapshot = dependencies.snapshot()
        try dependencies.disarm()
        do {
            try await drain()
        } catch {
            guard snapshot.wasLoaded else { throw error }
            do {
                try dependencies.rearm(snapshot.configPath)
            } catch let restoreError {
                throw TransactionError.restoreFailed(
                    drain: String(describing: error),
                    restore: String(describing: restoreError)
                )
            }
            throw error
        }
    }
}
