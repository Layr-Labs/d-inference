import Foundation
@_spi(OwnerService) import DarkbloomClusterProcess

/// Typed native-owner journal wrapper over the same exclusion used by solo.
/// Service lifecycle guards remain authoritative for resolving this journal.
@_spi(OwnerService) public final class ClusterDeviceLease {
    private let gate: ClusterDeviceExclusion
    public init(directoryURL: URL) throws { gate = try ClusterDeviceExclusion(directoryURL: directoryURL) }

    func record(binding: ClusterOwnerBinding, launchID: UUID) throws {
        try record(clusterID: binding.route.clusterID, peerID: binding.route.ownerPeerID, rank: binding.rank,
            membershipEpoch: binding.route.membershipEpoch, leaseID: binding.route.leaseID,
            ownerIncarnation: binding.route.ownerIncarnation, nativeLaunchID: launchID)
    }

    /// A finite installed child uses the same recovery journal without
    /// inventing a serving profile or capability. Record before spawning it.
    public func record(clusterID: String, peerID: String, rank: Int, membershipEpoch: UUID,
                       leaseID: UUID, ownerIncarnation: UUID, nativeLaunchID: UUID) throws {
        guard (0...1).contains(rank), (1...128).contains(clusterID.utf8.count),
              clusterID.utf8.allSatisfy({ (33...126).contains($0) }),
              !peerID.isEmpty, peerID.utf8.count <= 128,
              !peerID.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw ClusterOwnerStateError.invalid("Invalid finite-child journal identity")
        }
        var data = try JSONSerialization.data(withJSONObject: ["schema": "darkbloom_native_lease_v1",
            "clusterID": clusterID, "leaseID": leaseID.uuidString.lowercased(),
            "ownerIncarnation": ownerIncarnation.uuidString.lowercased(),
            "membershipEpoch": membershipEpoch.uuidString.lowercased(),
            "nativeLaunchID": nativeLaunchID.uuidString.lowercased(), "peerID": peerID,
            "rank": rank], options: [.sortedKeys])
        data.append(10)
        try gate.recordNativeOwnership(data)
    }

    /// Validates the actual held gate and exact own journal without releasing it.
    public func requireHeld() throws { try gate.requireHeldNativeOwnership() }

    /// Called only after this owner itself observed the exit of the child the
    /// journal names, or established that no child was launched.
    public func resolve() throws { try gate.resolveNativeOwnership() }
}
