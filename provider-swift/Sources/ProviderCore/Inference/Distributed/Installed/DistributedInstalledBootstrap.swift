import Foundation
import DarkbloomClusterRemote

/// How the two native ranks find each other, decided in one place.
///
/// The owner-authenticated exchange (S07) relays every bootstrap round through
/// both authenticated owners and the leader's relay: first the native key
/// prelude (the two workers agree an X25519 key bound to the committed start
/// the leader minted, which each owner admits only when it matches its own
/// installed setup), then JACCL's four mesh rounds over the same connections,
/// through the pinned mlx-c bridge. JACCL opens no TCP coordinator socket of
/// its own (the owner's oMLX lesson: Thunderbolt bootstrap sockets stuck in
/// SYN_SENT), and nothing unauthenticated answers on the link.
///
/// The direct native exchange (JACCL's own coordinator socket on the
/// configured link address, which nothing vouches for) stays selectable here
/// for diagnosis only; it is never a fallback.
public enum DistributedInstalledBootstrap: String, Codable, Sendable {
    case directNative, ownerAuthenticated

    /// The selection for this build.
    public static let installed: DistributedInstalledBootstrap = .ownerAuthenticated

    public var ownerAuthenticated: Bool { self == .ownerAuthenticated }
    var ownerProfile: ClusterOwnerBootstrapProfile? { self == .ownerAuthenticated ? .nativeKeyPreludeMesh2 : nil }
}
