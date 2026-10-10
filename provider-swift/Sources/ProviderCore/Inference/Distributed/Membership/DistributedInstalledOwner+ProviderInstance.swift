import Foundation

extension DistributedInstalledOwner {
    /// The fixed `cluster worker-owner --stdio` entry. Refuses while this Mac's
    /// ordinary provider holds its instance lock; see
    /// DistributedInstalledProviderExclusion for which holders are part of a cluster.
    public static func serve(reference: ClusterConfigurationReference) throws {
        try serve(reference: reference,
            providerInstanceLock: ProcessLifecycle.defaultPIDFile().appendingPathExtension("lock"),
            // A port macOS is reconfiguring at this moment gets a bounded wait,
            // instead of a rank that JACCL refuses for want of an IPv4-mapped GID.
            linkReady: { device in try ClusterLinkLaunchReadiness.waitForLink(device: device) })
    }
}
