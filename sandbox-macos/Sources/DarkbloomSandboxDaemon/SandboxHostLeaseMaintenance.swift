import Foundation
import SandboxRuntime
import SandboxRuntimeLume

/// Lease cleanup is independent of the coordinator connection and its retry
/// loop. It never releases capacity itself: the fenced runtime owns stop proof.
struct SandboxHostLeaseMaintenance: Sendable {
    let snapshot: @Sendable () throws -> [SandboxCapacityLease]
    let cancelCommands: @Sendable ([SandboxCapacityLease]) async -> Void
    let reconcile: @Sendable () async throws -> [LumeExpiredLeaseReconciliationResult]
    var now: @Sendable () -> Date = { Date() }
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var diagnostic: @Sendable (String) -> Void = {
        FileHandle.standardError.write(Data(($0 + "\n").utf8))
    }
    var interval: Duration = .seconds(1)

    func sweep() async throws -> [LumeExpiredLeaseReconciliationResult] {
        let date = now()
        let expired = try snapshot().filter { $0.expiresAt <= date }
        // Cancel every matching command first. Its existing bounded runtime
        // cancellation path completes stop proof before releasing execute locks.
        if !expired.isEmpty { await cancelCommands(expired) }
        try Task.checkCancellation()
        // Reconciliation also resumes already-authorized deletion intents,
        // including those whose lease deadline is still in the future.
        return try await reconcile()
    }

    func run() async throws {
        var lastMessage: String?
        var lastReportedAt = Date.distantPast
        while !Task.isCancelled {
            let message: String?
            do {
                let outcomes = try await sweep()
                let retained = outcomes.filter {
                    if case .retained = $0.outcome { return true }
                    return false
                }.count
                message = retained > 0
                    ? "sandbox lease maintenance retained \(retained) expired lease(s); cleanup will retry"
                    : nil
            } catch is CancellationError { throw CancellationError() }
            catch {
                // Error text can contain runtime paths. Keep recurring logs
                // bounded; detailed retained outcomes remain available to ops.
                message = "sandbox lease maintenance unavailable; reservations retained and cleanup will retry"
            }
            let date = now()
            if let message {
                if message != lastMessage || date.timeIntervalSince(lastReportedAt) >= 60 {
                    diagnostic(message)
                    lastReportedAt = date
                }
            } else if lastMessage != nil {
                diagnostic("sandbox lease maintenance recovered")
            }
            lastMessage = message
            try await sleep(interval)
        }
    }
}
