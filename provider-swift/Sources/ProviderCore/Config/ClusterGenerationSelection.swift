import Foundation
import DarkbloomClusterProtocol

/// Which generation modes a saved setup may name.
///
/// A capability record is written by the worker it describes and carries that
/// worker's binary hash. A cluster setup pins one record and requires both
/// members' workers to be that build, so the one record describes both
/// workers. A mode is usable when the record advertises it; anything else is
/// refused when the setup is read, long before a worker is launched.
enum ClusterGenerationSelection {
    /// What the pinned record advertises for this member's worker: its list
    /// when it describes the build the member runs, nothing otherwise.
    static func supportedModes(for peer: ClusterConfiguration.Peer,
                               capability: ClusterRuntimeCapability) -> [ClusterGenerationMode] {
        peer.runtimeBinarySHA256 == capability.runtimeBinarySHA256 ? capability.supportedGenerationModes : []
    }

    static func requireSupport(for mode: ClusterGenerationMode, peers: [ClusterConfiguration.Peer],
                               capability: ClusterRuntimeCapability) throws {
        guard let peer = peers.first(where: { !supportedModes(for: $0, capability: capability).contains(mode) }) else { return }
        let advertised = supportedModes(for: peer, capability: capability).map(\.rawValue).joined(separator: ", ")
        throw ClusterConfigurationError.invalid("Generation mode \(mode.rawValue) is not advertised by the worker of member \(peer.id) "
            + "(\(peer.workerExecutable), build \(peer.runtimeBinarySHA256.prefix(12))), which advertises: \(advertised.isEmpty ? "nothing in the saved record" : advertised). "
            + "Name one of the advertised modes, or install a worker that supports \(mode.rawValue) on both Macs and run `darkbloom cluster configure` again.")
    }
}
