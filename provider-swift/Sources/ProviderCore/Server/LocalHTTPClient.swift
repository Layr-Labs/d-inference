import NIOCore

/// Where a local API request came from, for the router's paid hop (`prefer`): a program on this Mac (a loopback peer,
/// 127.0.0.0/8 or ::1) or another machine. Decided once per connection from its TCP peer, never from a header
/// (`LocalHTTPConnectionCancellation.fromAnotherMachine`).
enum LocalHTTPClient {
    /// True while the request came from another machine. `LocalDisconnectResponder` binds it for such a connection's
    /// requests only, so a request from this Mac binds nothing.
    @TaskLocal static var fromAnotherMachine = false

    /// Whether a connection whose TCP peer is `peer` comes from another machine: any address but loopback, counting an
    /// IPv4 loopback peer that a dual-stack listener sees as `::ffff:127.x.y.z`. A channel without a peer (in process)
    /// or a Unix socket is this Mac's.
    static func isAnotherMachine(peer: SocketAddress?) -> Bool {
        switch peer {
        case .v4(let address)?:
            return UInt32(bigEndian: address.address.sin_addr.s_addr) >> 24 != 127
        case .v6(let address)?:
            return withUnsafeBytes(of: address.address.sin6_addr) { bytes in
                let loopback = bytes[0..<15].allSatisfy { $0 == 0 } && bytes[15] == 1
                let mappedLoopback = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
                    && bytes[12] == 127
                return !loopback && !mappedLoopback
            }
        case .unixDomainSocket?, nil:
            return false
        }
    }
}
