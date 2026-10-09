import Foundation

extension DistributedInstalledOwner {
    /// The fixed `cluster worker-owner --stdio` entry. Refuses while this Mac's
    /// ordinary provider holds its instance lock; see
    /// DistributedInstalledProviderExclusion for which holders are part of a cluster.
    public static func serve(reference: ClusterConfigurationReference) throws {
        try serve(reference: reference,
            providerInstanceLock: ProcessLifecycle.defaultPIDFile().appendingPathExtension("lock"))
    }
}
