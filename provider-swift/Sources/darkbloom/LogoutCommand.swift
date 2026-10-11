import ArgumentParser
import Foundation
import ProviderCore

struct Logout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop the provider, revoke its saved token, and remove local account credentials."
    )

    @OptionGroup var configOptions: ConfigOptions
    @OptionGroup var drain: DrainOptions

    mutating func run() async throws {
        let config = try loadRuntimeConfiguration(configPath: configOptions.config).config
        let previous = Self.localProviderIdentities()
        // Keep start/recovery fenced until the saved token is gone, not merely
        // until Stop has finished. A missing token file does not skip the stop.
        let session = try await ServiceDrain.prepare(options: drain)
        defer { session.release() }
        var instanceLock: URL?
        defer {
            if let instanceLock { ProcessLifecycle.releaseSingleInstanceLock(at: instanceLock) }
        }
        let outcome = try await ProviderLogout.perform(stopProvider: {
            try await ServiceDrain.stopDrainedProvider()
            try LaunchAgent.stop()
            try Self.requireExited(previous + Self.localProviderIdentities())
            // Foreground start uses this lock even when no launchd job exists.
            instanceLock = try ProcessLifecycle.acquireSingleInstanceLock()
        }, revokeToken: { token in
            await ProviderLogout.revokeToken(token, coordinatorURL: config.coordinator.url)
        })
        for line in Self.completionLines(for: outcome) { print(line) }
    }

    private static func localProviderIdentities() -> [ProcessIdentity] {
        [DaemonStateFile.read()?.processIdentity,
         LaunchAgent.launchSnapshot()?.process,
         ProcessLifecycle.existingPID().flatMap { ProcessIdentity.read(pid: $0) }].compactMap { $0 }
    }

    static func requireExited(_ identities: [ProcessIdentity]) throws {
        guard !identities.contains(where: { $0.isCurrent() }) else {
            throw ValidationError("A provider process is still running or shutting down. Stop any foreground darkbloom process, then retry logout. The saved credential has not been removed.")
        }
    }

    static func completionLines(for outcome: ProviderLogout.Outcome) -> [String] {
        let stopped = "Provider stopped. Automatic restart is disabled until you run `darkbloom start` again."
        switch outcome {
        case .revoked:
            return [stopped, "Logged out. This provider token was revoked and the local credential was removed."]
        case .remoteUnconfirmed:
            return [stopped, "Logged out locally. The saved provider credential was removed.",
                "Warning: Remote token invalidation was not confirmed. The coordinator may be offline or may not support device revocation."]
        case .noCredential:
            return [stopped, "No saved provider credential was found. Remote token invalidation could not be confirmed."]
        }
    }
}
