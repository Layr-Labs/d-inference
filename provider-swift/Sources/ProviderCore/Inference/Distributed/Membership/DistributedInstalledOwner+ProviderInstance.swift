import Foundation

extension DistributedInstalledOwner {
    /// The fixed `cluster worker-owner --stdio` entry. Refuses while this Mac's
    /// ordinary provider holds its instance lock (see
    /// DistributedInstalledProviderExclusion for which holders are part of a
    /// cluster), and when the model's pair-serving grant refuses the rank this
    /// Mac runs (mode family not granted, or a rank-shape that diverged).
    public static func serve(reference: ClusterConfigurationReference) throws {
        try serve(reference: reference,
            providerInstanceLock: ProcessLifecycle.defaultPIDFile().appendingPathExtension("lock"),
            localChipClass: ClusterChipClass.local(),
            // A port macOS is reconfiguring at this moment gets a bounded wait,
            // instead of a rank that JACCL refuses for want of an IPv4-mapped GID.
            linkReady: { device in try ClusterLinkLaunchReadiness.waitForLink(device: device) })
    }
}
