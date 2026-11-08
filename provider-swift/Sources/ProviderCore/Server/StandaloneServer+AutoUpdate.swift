import Foundation

/// StandaloneServer -- background self-update of Only me's background service.
extension StandaloneServer {
    /// Starts the update cycle; nothing yet.
    public func startAutoUpdateMonitor(coordinatorURL: String, enabled: Bool,
                                       environment: [String: String] = ProcessInfo.processInfo.environment) {}

    /// Admission closes; requests already accepted finish. Nothing yet.
    func beginUpdateDrain() {}

    /// Whether every accepted request finished within `timeout`.
    func waitForUpdateDrain(_ timeout: Duration) async -> Bool { true }

    /// Back to serving after a cycle that didn't restart.
    func resumeAfterUpdate() {}
}
