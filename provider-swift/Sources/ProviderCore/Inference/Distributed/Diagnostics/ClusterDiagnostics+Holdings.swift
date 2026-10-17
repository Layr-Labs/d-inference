import Foundation

extension ClusterDiagnostics {
    /// For `darkbloom cluster status`: what each Mac holds while a session of
    /// the saved setup is up, or why that could not be read. Nil when no setup
    /// is saved or it cannot be loaded; the status report itself says which.
    /// It reads the saved setup and runs the installed plan tool's `layout`
    /// on the saved model directory: tensor headers only, no model load, no
    /// peer contacted.
    public static func holdings(providerConfiguration: URL) -> ClusterInstalledHoldings.Observation? {
        guard let paths = try? ClusterUserPaths(),
              let reference = try? ClusterConfigurationStore.optionalInstalledReference(providerConfiguration: providerConfiguration),
              let saved = try? ClusterConfigurationStore(paths: paths).load(reference: reference) else { return nil }
        return ClusterInstalledHoldings.observe(configuration: saved.configuration, capability: saved.capability,
            deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
    }
}
