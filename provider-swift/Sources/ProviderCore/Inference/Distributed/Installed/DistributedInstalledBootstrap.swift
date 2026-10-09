import Foundation
import DarkbloomClusterRemote

/// How the two native ranks find each other, decided in one place.
///
/// The owner-authenticated exchange relays every bootstrap round through both
/// authenticated owners. It needs a runtime bridge that this build's pinned
/// runtime does not carry, and the installed worker refuses its arguments.
/// Until that bridge is pinned, the installed path uses the runtime's own
/// exchange on the configured link address and says so in its status: nothing
/// vouches for the peer that answers there.
///
/// The argument and owner contracts for the authenticated exchange stay in
/// place; switching back is this one value.
public enum DistributedInstalledBootstrap: String, Codable, Sendable {
    case directNative, ownerAuthenticated

    /// The selection for this build.
    public static let installed: DistributedInstalledBootstrap = .directNative

    public var ownerAuthenticated: Bool { self == .ownerAuthenticated }
    var ownerProfile: ClusterOwnerBootstrapProfile? { self == .ownerAuthenticated ? .mesh2 : nil }
}
