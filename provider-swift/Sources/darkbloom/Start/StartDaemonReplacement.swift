import ArgumentParser
import Foundation
import ProviderCore

extension Start {
    /// Called after the drain acknowledgement while holding the lifecycle lease.
    /// Persistence must succeed before the existing process or service is stopped.
    static func completeDaemonReplacement(
        autopilot: Bool, models: [String], configPath: String?,
        stop: () async throws -> Void = { try await ServiceDrain.stopDrainedProvider() },
        install: () throws -> Void
    ) async throws {
        do {
            try saveAutopilotEnrollment(enabled: autopilot, models: models, configPath: configPath)
        } catch {
            throw ValidationError("Could not save Autopilot configuration: \(error). Correct the configuration and retry start. A gracefully drained provider is left running; no replacement was started.")
        }
        try await stop()
        try install()
    }
}
