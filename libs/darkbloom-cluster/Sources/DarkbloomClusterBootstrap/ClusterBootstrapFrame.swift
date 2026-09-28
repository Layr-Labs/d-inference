import Foundation

public enum ClusterBootstrapError: Error, Equatable, Sendable {
    case invalid(String), peer, deadline, closed, system(Int32)
}

public struct ClusterBootstrapIdentity: Equatable, Sendable {
    public let membershipEpoch: UUID
    public let rank: Int
    public init(membershipEpoch: UUID, rank: Int) throws {
        guard (0...1).contains(rank) else { throw ClusterBootstrapError.invalid("Bootstrap requires two ranks") }
        self.membershipEpoch = membershipEpoch; self.rank = rank
    }
}

/// Native payload bytes are opaque. This local route is not peer authentication.
public struct ClusterBootstrapRound: Equatable, Sendable {
    public let identity: ClusterBootstrapIdentity
    public let sequence: UInt64
    public let contribution: Data
    public init(identity: ClusterBootstrapIdentity, sequence: UInt64, contribution: Data) throws {
        guard sequence < 6, (1...65_536).contains(contribution.count) else {
            throw ClusterBootstrapError.invalid("Bootstrap round exceeds bounds")
        }
        self.identity = identity; self.sequence = sequence; self.contribution = contribution
    }
}

struct BootstrapHeader {
    static let byteCount = 40
    let identity: ClusterBootstrapIdentity
    let sequence: UInt64
    let contributionBytes: Int
    let reply: Bool
    var payloadBytes: Int { contributionBytes * (reply ? 2 : 1) }

    init(round: ClusterBootstrapRound, reply: Bool) {
        identity = round.identity; sequence = round.sequence
        contributionBytes = round.contribution.count; self.reply = reply
    }

    func encoded() -> Data {
        var data = Data([0x44, 0x42, 0x4a, 0x42, 1, reply ? 2 : 1, UInt8(identity.rank), 2])
        var uuid = identity.membershipEpoch.uuid
        withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
        for (value, count) in [(sequence, 8), (UInt64(contributionBytes), 4), (UInt64(payloadBytes), 4)] {
            for shift in stride(from: (count - 1) * 8, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        return data
    }

    init(_ data: Data) throws {
        let bytes = Array(data)
        guard bytes.count == Self.byteCount, Array(bytes[0..<5]) == [0x44, 0x42, 0x4a, 0x42, 1],
              [1, 2].contains(bytes[5]), bytes[6] < 2, bytes[7] == 2 else {
            throw ClusterBootstrapError.invalid("Invalid bootstrap header")
        }
        let uuid: uuid_t = (bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
            bytes[16], bytes[17], bytes[18], bytes[19], bytes[20], bytes[21], bytes[22], bytes[23])
        identity = try .init(membershipEpoch: UUID(uuid: uuid), rank: Int(bytes[6]))
        func number(_ range: Range<Int>) -> UInt64 { range.reduce(0) { ($0 << 8) | UInt64(bytes[$1]) } }
        sequence = number(24..<32); contributionBytes = Int(number(32..<36)); reply = bytes[5] == 2
        guard sequence < 6, (1...65_536).contains(contributionBytes), number(36..<40) == UInt64(payloadBytes) else {
            throw ClusterBootstrapError.invalid("Invalid bootstrap length or sequence")
        }
    }
}
