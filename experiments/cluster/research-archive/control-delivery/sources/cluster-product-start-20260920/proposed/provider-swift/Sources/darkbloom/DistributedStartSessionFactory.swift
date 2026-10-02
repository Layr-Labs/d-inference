import Foundation
import ArgumentParser
import ProviderCore

/// Capture one selected setup, but prepare a NEW installed session each time.
/// The host alone starts owners and publishes the new generation after release.
struct DistributedStartSessionFactory: Sendable {
    let providerConfiguration: URL
    let reference: ClusterConfigurationReference

    init(providerConfiguration: URL,
         ownerConfiguration: () throws -> URL = ConfigManager.defaultConfigPath) throws {
        self.providerConfiguration = providerConfiguration
        reference = try ClusterConfigurationStore.installedReference(providerConfiguration: providerConfiguration)
        try requireCurrentReferences(ownerConfiguration: ownerConfiguration())
    }

    func selectedTransport() throws -> ClusterConfiguration.Transport {
        try withCurrentReference { reference in
            try ClusterConfigurationStore(paths: ClusterUserPaths()).load(reference: reference).configuration.selectedTransport
        }
    }

    func prepare() async throws -> DistributedInstalledSession {
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            try self.withCurrentReference { reference in
                // Re-run the existing bounded metadata/trust/capability checks.
                // prepare mints a fresh epoch and never starts native owners.
                try DistributedInstalledSession.prepare(reference: reference)
            }
        }.value
    }

    /// Synchronous metadata boundary also used by actual-file tests. Re-resolve
    /// the owner's default path after preparation; it may have changed meanwhile.
    func withCurrentReference<Result>(
        ownerConfiguration: () throws -> URL = ConfigManager.defaultConfigPath,
        _ body: (ClusterConfigurationReference) throws -> Result
    ) throws -> Result {
        try requireCurrentReferences(ownerConfiguration: ownerConfiguration())
        let result = try body(reference)
        try requireCurrentReferences(ownerConfiguration: ownerConfiguration())
        return result
    }

    private func requireCurrentReferences(ownerConfiguration: URL) throws {
        let selected = try ClusterConfigurationStore.installedReference(providerConfiguration: providerConfiguration)
        let owner = try ClusterConfigurationStore.installedReference(providerConfiguration: ownerConfiguration)
        guard selected == reference, owner == reference else {
            throw ValidationError("The selected cluster and installed owner's default setup must remain unchanged while distributed serving is active.")
        }
    }
}
