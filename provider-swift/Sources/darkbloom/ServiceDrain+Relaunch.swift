import Foundation
import ProviderCore

extension ServiceDrain {
    /// Relaunch a drained provider and re-arm the watchdog whether or not the
    /// relaunch succeeds. `prepare` stopped and disabled the watchdog, so a
    /// relaunch that throws must not leave crash recovery off.
    static func relaunchDrainedProvider(
        relaunch: () async throws -> Void,
        rearm: () -> Void
    ) async throws {
        defer { rearm() }
        try await relaunch()
    }
}
