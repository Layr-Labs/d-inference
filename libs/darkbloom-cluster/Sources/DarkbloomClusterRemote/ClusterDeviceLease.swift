import Foundation
@_spi(OwnerService) import DarkbloomClusterProcess

/// Typed native-owner journal wrapper over the same exclusion used by solo.
/// Service lifecycle guards remain authoritative for resolving this journal.
final class ClusterDeviceLease {
    private let gate: ClusterDeviceExclusion
    init(directoryURL: URL) throws { gate = try ClusterDeviceExclusion(directoryURL: directoryURL) }

    func record(binding: ClusterOwnerBinding, launchID: UUID) throws {
        var data = try JSONSerialization.data(withJSONObject: ["schema": "darkbloom_native_lease_v1",
            "clusterID": binding.route.clusterID, "leaseID": binding.route.leaseID.uuidString.lowercased(),
            "ownerIncarnation": binding.route.ownerIncarnation.uuidString.lowercased(),
            "membershipEpoch": binding.route.membershipEpoch.uuidString.lowercased(),
            "nativeLaunchID": launchID.uuidString.lowercased(), "peerID": binding.route.ownerPeerID,
            "rank": binding.rank], options: [.sortedKeys])
        data.append(10)
        try gate.recordNativeOwnership(data)
    }

    /// Called only after existing service checks prove actual native cleanup and
    /// receipt of the current connection's release acknowledgement.
    func resolve() throws { try gate.resolveNativeOwnership() }
}
