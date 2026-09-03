import Foundation

/// A MAC address.
public struct MACAddress: Equatable, Hashable, Sendable, CustomStringConvertible {
    public static let byteCount = 6
    public static let broadcast = MACAddress(
        bytes: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], unchecked: ()
    )

    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }

    private init(bytes: [UInt8], unchecked: Void = ()) {
        self.bytes = bytes
    }

    /// Parses the `aa:bb:cc:dd:ee:ff` form Lume writes into a VM's config.
    public init?(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == Self.byteCount else { return nil }
        var parsed: [UInt8] = []
        parsed.reserveCapacity(Self.byteCount)
        for part in parts {
            guard part.count == 2, let byte = UInt8(part, radix: 16) else {
                return nil
            }
            parsed.append(byte)
        }
        bytes = parsed
    }

    public var description: String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Whether this address is a group address, which covers broadcast and all
    /// multicast. The low bit of the first octet is the individual/group bit.
    public var isGroup: Bool { (bytes[0] & 0x01) == 0x01 }
}

/// The EtherTypes this gateway understands. Anything else is dropped: a guest
/// can emit any protocol it likes, and silently forwarding one nobody parsed
/// would be exactly the hole the gateway exists to close.
public enum EtherType: UInt16, Sendable {
    case ipv4 = 0x0800
    case arp = 0x0806
    case ipv6 = 0x86DD
}

/// One Ethernet frame, as delivered by `VZFileHandleNetworkDeviceAttachment`.
///
/// The attachment delivers exactly one frame per datagram with no length
/// prefix, so a frame's bounds are the datagram's bounds and nothing has to be
/// reassembled.
public struct EthernetFrame: Equatable, Sendable {
    public static let headerBytes = 14

    public let destination: MACAddress
    public let source: MACAddress
    /// The raw type field. Kept raw rather than as `EtherType` so an unknown
    /// protocol can be counted and reported rather than becoming unparseable.
    public let rawEtherType: UInt16
    public let payload: [UInt8]

    public var etherType: EtherType? { EtherType(rawValue: rawEtherType) }

    public init(
        destination: MACAddress,
        source: MACAddress,
        rawEtherType: UInt16,
        payload: [UInt8]
    ) {
        self.destination = destination
        self.source = source
        self.rawEtherType = rawEtherType
        self.payload = payload
    }

    /// Decodes a frame, or returns nil if it is too short to be one.
    ///
    /// 🛑 A frame carrying an 802.1Q tag (`0x8100`) is *not* unwrapped here. The
    /// gateway hands the guest an untagged link, so a tagged frame is something
    /// the guest invented; it decodes with `rawEtherType == 0x8100` and is
    /// dropped as unknown rather than being silently unwrapped into whatever is
    /// inside.
    public init?(decoding bytes: [UInt8]) {
        guard bytes.count >= Self.headerBytes else { return nil }
        guard let destination = MACAddress(bytes: Array(bytes[0..<6])),
              let source = MACAddress(bytes: Array(bytes[6..<12]))
        else {
            return nil
        }
        self.destination = destination
        self.source = source
        rawEtherType = UInt16(bytes[12]) << 8 | UInt16(bytes[13])
        payload = Array(bytes[Self.headerBytes...])
    }

    public func encoded() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(Self.headerBytes + payload.count)
        out.append(contentsOf: destination.bytes)
        out.append(contentsOf: source.bytes)
        out.append(UInt8(truncatingIfNeeded: rawEtherType >> 8))
        out.append(UInt8(truncatingIfNeeded: rawEtherType))
        out.append(contentsOf: payload)
        return out
    }
}
