import Foundation
import ProviderCore

/// Bridges AppKit process signals to the currently running `ProviderLoop`.
/// Keeping the handler in an actor makes repeated SIGTERM/SIGINT deliveries
/// coalesce onto one drain attempt.
actor ProviderTerminationRelay {
    static let shared = ProviderTerminationRelay()

    typealias Handler = @Sendable () async -> OperatorDrainController.Outcome

    private var handler: Handler?
    private var active: (id: UUID, task: Task<OperatorDrainController.Outcome, Never>)?

    func install(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func uninstall() {
        handler = nil
    }

    func request() async -> OperatorDrainController.Outcome {
        if let active {
            return await active.task.value
        }
        guard let handler else { return .unavailable }

        let id = UUID()
        let task = Task { await handler() }
        active = (id, task)
        let outcome = await task.value
        if active?.id == id {
            active = nil
        }
        return outcome
    }
}
