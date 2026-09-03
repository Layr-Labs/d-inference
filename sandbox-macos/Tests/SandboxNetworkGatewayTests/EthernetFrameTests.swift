import Darwin
import Foundation
import XCTest

@testable import SandboxNetworkGateway

final class EthernetFrameTests: XCTestCase {
    func testDecodesAFrameTheGuestWouldActuallySend() throws {
        // A broadcast ARP, which is the first thing a booting guest emits.
        var bytes: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        bytes += [0x0A, 0x00, 0x27, 0x00, 0x00, 0x01]
        bytes += [0x08, 0x06]
        bytes += [0xDE, 0xAD, 0xBE, 0xEF]

        let frame = try XCTUnwrap(EthernetFrame(decoding: bytes))

        XCTAssertEqual(frame.destination, MACAddress.broadcast)
        XCTAssertEqual(frame.source.description, "0a:00:27:00:00:01")
        XCTAssertEqual(frame.etherType, .arp)
        XCTAssertEqual(frame.payload, [0xDE, 0xAD, 0xBE, 0xEF])
        // Round-trips, so anything the gateway relays is byte-identical.
        XCTAssertEqual(frame.encoded(), bytes)
    }

    func testRefusesFramesTooShortToBeFrames() {
        XCTAssertNil(EthernetFrame(decoding: []))
        XCTAssertNil(EthernetFrame(decoding: [UInt8](repeating: 0, count: 13)))
        // Exactly a header and no payload is legal; the payload is empty.
        let bare = EthernetFrame(decoding: [UInt8](repeating: 0, count: 14))
        XCTAssertNotNil(bare)
        XCTAssertEqual(bare?.payload, [])
    }

    /// A guest can emit any EtherType. Keeping the raw value means an unknown
    /// one is droppable and countable rather than unparseable — and a VLAN tag
    /// is not silently unwrapped into whatever it contains.
    func testUnknownEtherTypesSurviveAsRawValues() throws {
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes += [0x81, 0x00]                       // 802.1Q tag
        bytes += [0x00, 0x64, 0x08, 0x00]

        let frame = try XCTUnwrap(EthernetFrame(decoding: bytes))

        XCTAssertEqual(frame.rawEtherType, 0x8100)
        XCTAssertNil(
            frame.etherType,
            "a tagged frame must not decode as the protocol inside it"
        )
    }

    func testMACParsingAndGroupBit() throws {
        XCTAssertEqual(MACAddress("0a:00:27:00:00:01")?.bytes.count, 6)
        XCTAssertNil(MACAddress("0a:00:27:00:00"))
        XCTAssertNil(MACAddress("0a:00:27:00:00:zz"))
        XCTAssertNil(MACAddress("0a000270000 1"))

        // Broadcast and multicast both set the group bit; a unicast MAC the
        // gateway hands out must not.
        XCTAssertTrue(MACAddress.broadcast.isGroup)
        let multicast = try XCTUnwrap(MACAddress("01:00:5e:00:00:fb"))
        XCTAssertTrue(multicast.isGroup)
        let unicast = try XCTUnwrap(MACAddress("0a:00:27:00:00:01"))
        XCTAssertFalse(unicast.isGroup)
    }
}

final class GuestFrameChannelTests: XCTestCase {
    private func datagramPair() throws -> (Int32, Int32) {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &pair) == 0 else {
            throw XCTSkip("socketpair unavailable")
        }
        let flags = fcntl(pair[0], F_GETFL)
        _ = fcntl(pair[0], F_SETFL, flags | O_NONBLOCK)
        return (pair[0], pair[1])
    }

    /// One datagram is one frame. This is the property the whole gateway rests
    /// on: no length prefix, no reassembly, and two frames never splice.
    func testEachDatagramIsExactlyOneFrame() throws {
        let (host, guest) = try datagramPair()
        defer { close(host); close(guest) }
        let channel = GuestFrameChannel(descriptor: host)

        let first = [UInt8](repeating: 0xA1, count: 60)
        let second = [UInt8](repeating: 0xB2, count: 1514)
        for frame in [first, second] {
            _ = frame.withUnsafeBytes { send(guest, $0.baseAddress, $0.count, 0) }
        }

        XCTAssertEqual(try channel.receive(), first)
        XCTAssertEqual(try channel.receive(), second)
        XCTAssertNil(try channel.receive(), "an empty queue is nil, not a stall")
    }

    func testAClosedPeerIsReportedSoTheGatewayCanStop() throws {
        let (host, guest) = try datagramPair()
        defer { close(host) }
        let channel = GuestFrameChannel(descriptor: host)
        close(guest)

        // The guest's network must die with its VM rather than linger.
        XCTAssertThrowsError(try channel.receive()) { error in
            XCTAssertEqual(
                error as? GuestFrameChannel.ChannelError, .closed
            )
        }
    }

    func testAnOversizedFrameIsRefusedRatherThanTruncated() throws {
        let (host, guest) = try datagramPair()
        defer { close(host); close(guest) }
        let channel = GuestFrameChannel(descriptor: host, maximumFrameBytes: 1514)

        XCTAssertThrowsError(
            try channel.send([UInt8](repeating: 0, count: 1515))
        ) { error in
            XCTAssertEqual(
                error as? GuestFrameChannel.ChannelError,
                .failed(errno: EMSGSIZE),
                "a truncated frame would reach the guest as corruption"
            )
        }
        XCTAssertNoThrow(try channel.send([UInt8](repeating: 0, count: 1514)))
    }
}
