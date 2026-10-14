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
        var previous: [ProcessIdentity] = []
        // Keep start/recovery fenced until the saved token is gone, not merely
        // until Stop has finished. A missing token file does not skip the stop.
        let session = try await ServiceDrain.prepare(options: drain, withConfigurationChange: { publish in
            previous = Self.localProviderIdentities()
            try publish()
        })
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
            await Self.revokeSavedToken(token)
        })
        for line in Self.completionLines(for: outcome) { print(line) }
    }

    // Configuration and daemon state cannot prove who issued this saved token.
    // Legacy credentials without bound issuer metadata are deleted locally only.
    static func revokeSavedToken(
        _ token: String,
        issuer: (String) -> String? = AuthTokenStore.issuer,
        revoke: (String, String) async -> Bool = { await ProviderLogout.revokeToken($0, coordinatorURL: $1) }
    ) async -> Bool {
        guard let coordinator = issuer(token) else { return false }
        return await revoke(token, coordinator)
    }

    private static func localProviderIdentities() -> [ProcessIdentity] {
        providerIdentities(state: DaemonStateFile.read(), launchProcess: LaunchAgent.launchSnapshot()?.process)
    }

    static func providerIdentities(state: DaemonState?, launchProcess: ProcessIdentity?) -> [ProcessIdentity] {
        let recorded = state.flatMap { state in
            state.processIdentity.flatMap { $0.pid == state.pid ? $0 : nil }
        }
        return [recorded, launchProcess].compactMap { $0 }
    }

    static func requireExited(_ identities: [ProcessIdentity]) throws {
        guard !identities.contains(where: { $0.isCurrent() }) else {
            throw ValidationError("A provider process is still running or shutting down. Stop any foreground \(BuildEnvironment.current.cliName) process, then retry logout. The saved credential has not been removed.")
        }
    }

    static func completionLines(for outcome: ProviderLogout.Outcome) -> [String] {
        let stopped = "Provider stopped. Automatic restart is disabled until you run `\(BuildEnvironment.current.cliName) start` again."
        switch outcome {
        case .revoked:
            return [stopped, "Logged out. This provider token was revoked and the local credential was removed."]
        case .remoteUnconfirmed:
            return [stopped, "Logged out locally. The saved provider credential was removed.",
                "Warning: Remote token invalidation was not confirmed. The coordinator could not be determined or reached, or it may not support device revocation."]
        case .noCredential:
            return [stopped, "No saved provider credential was found. Remote token invalidation could not be confirmed."]
        }
    }
}
