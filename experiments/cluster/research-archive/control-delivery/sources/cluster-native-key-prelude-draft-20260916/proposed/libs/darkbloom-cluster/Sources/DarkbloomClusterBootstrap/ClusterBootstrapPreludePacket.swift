import Foundation

/// Closed, fixed header. No JSON duplicate fields, optional downgrade, arbitrary
/// operation or allocation based on an unbounded received length is permitted.
enum PreludePacket {
    enum Kind: UInt8 {
        case start = 1, hello, binding, confirmation, peerConfirmation, complete
        var sequence: UInt32 { UInt32(rawValue - 1) }
        var fixedCount: Int? {
            switch self { case .confirmation, .peerConfirmation, .complete: 32; default: nil }
        }
    }
    static let maximumBytes = 32 * 1024
    static let headerBytes = 32
    static func header(kind: Kind, count: Int, identity: ClusterBootstrapIdentity) throws -> Data {
        guard (1...maximumBytes).contains(count), kind.fixedCount.map({ $0 == count }) ?? true else {
            throw ClusterBootstrapError.invalid("Native authorization packet size differs")
        }
        var result = Data([0x44, 0x42, 0x4e, 0x50, 1, kind.rawValue, UInt8(identity.rank), 0])
        var uuid = identity.membershipEpoch.uuid
        withUnsafeBytes(of: &uuid) { result.append(contentsOf: $0) }
        for value in [kind.sequence, UInt32(count)] {
            var n = value.bigEndian; withUnsafeBytes(of: &n) { result.append(contentsOf: $0) }
        }
        return result
    }
    static func write(_ bytes: Data, kind: Kind, socket: BootstrapSocket, identity: ClusterBootstrapIdentity) throws {
        try socket.write(header(kind: kind, count: bytes.count, identity: identity))
        try socket.write(bytes)
    }
    static func read(_ kind: Kind, socket: BootstrapSocket, identity: ClusterBootstrapIdentity) throws -> Data {
        let observed = try socket.readExactly(headerBytes)
        let values = Array(observed)
        let count = values[28..<32].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count <= UInt32(maximumBytes),
              observed == (try header(kind: kind, count: Int(count), identity: identity)) else {
            throw ClusterBootstrapError.invalid("Native authorization header differs")
        }
        return try socket.readExactly(Int(count))
    }
}
